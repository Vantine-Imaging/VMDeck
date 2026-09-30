import Foundation

/// Which VMs a host starts on its own, and how patiently it waits for them.
struct AutoStartConfig: Equatable, Sendable {
    /// .vmx paths, in start order.
    var vmxPaths: [String] = []
    /// How long to wait for a VM's files to appear (a volume still mounting).
    var waitSeconds: Int = 600
    /// Pause between starts, so guests don't all boot at once.
    var staggerSeconds: Int = 15

    var isEmpty: Bool { vmxPaths.isEmpty }
}

struct AutoStartStatus: Equatable, Sendable {
    var config = AutoStartConfig()
    /// The LaunchAgent plist exists on the host.
    var installed = false
    /// launchd has it loaded for the logged-in user.
    var loaded = false
    /// Whoever is logged in at the host's screen; nil means nobody.
    var consoleUser: String?
    /// macOS automatic login, needed for the agent to run after a reboot
    /// without someone logging in.
    var autoLoginUser: String?
    /// Last lines of the auto-start log.
    var recentLog: String = ""
}

/// Installs and manages a per-user LaunchAgent on a host that starts chosen
/// VMs headless at login, waiting for volumes that mount late.
///
/// It's a LaunchAgent, not a LaunchDaemon, on purpose: Fusion VMs belong to a
/// user, and `vmrun` needs that user's session. The trade-off is that nothing
/// runs after a reboot until that user logs in, hence the auto-login check.
struct AutoStartManager: Sendable {
    let vmrun: VMRun

    static let label = "com.vantine.vmdeck.autostart"

    func status() async throws -> AutoStartStatus {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.statusScript, "vmdeck-autostart-status"],
                                                timeout: .seconds(20))
        try VMRun.check(result)
        return Self.parseStatus(result.stdout)
    }

    /// Writes the script, list, and LaunchAgent, then (re)loads the agent.
    /// An empty list uninstalls everything.
    func install(_ config: AutoStartConfig) async throws {
        var argv = ["/bin/sh", "-c", Self.installScript, "vmdeck-autostart-install",
                    vmrun.vmrunPath, String(config.waitSeconds), String(config.staggerSeconds), "1", Self.runnerScript]
        argv += config.vmxPaths
        let result = try await vmrun.runner.run(argv, timeout: .seconds(30))
        try VMRun.check(result)
    }

    /// Runs the agent right now, the same way login would.
    func runNow() async throws {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.runNowScript, "vmdeck-autostart-run"],
                                                timeout: .seconds(30))
        try VMRun.check(result)
    }

    static func parseStatus(_ output: String) -> AutoStartStatus {
        var status = AutoStartStatus()
        var logLines: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let value = f.count > 1 ? f[1] : ""
            switch f[0] {
            case "INSTALLED": status.installed = value == "1"
            case "LOADED": status.loaded = value == "1"
            case "WAIT": status.config.waitSeconds = Int(value) ?? status.config.waitSeconds
            case "STAGGER": status.config.staggerSeconds = Int(value) ?? status.config.staggerSeconds
            case "VM": status.config.vmxPaths.append(value)
            case "CONSOLE": status.consoleUser = value.isEmpty ? nil : value
            case "AUTOLOGIN": status.autoLoginUser = value.isEmpty ? nil : value
            case "LOG": logLines.append(value)
            default: continue
            }
        }
        status.recentLog = logLines.joined(separator: "\n")
        return status
    }

    // MARK: - Host-side scripts

    static let supportDir = "$HOME/Library/Application Support/VMDeck"
    static let listFile = "\(supportDir)/autostart.list"
    static let scriptFile = "\(supportDir)/autostart.sh"
    static let logFile = "$HOME/Library/Logs/VMDeck/autostart.log"
    static let plistFile = "$HOME/Library/LaunchAgents/\(label).plist"

    /// The script the LaunchAgent runs. The list file's line 1 is
    /// `wait stagger`, line 2 the vmrun path, and the rest .vmx paths in
    /// start order. The script itself never changes, so it's safe to
    /// overwrite on every save.
    static let runnerScript = #"""
    #!/bin/sh
    # Written by VMDeck. Starts the VMs listed in autostart.list headless,
    # waiting for each one's files to appear first (external volumes can
    # mount well after login). Edit the list in VMDeck, not here.
    LIST="$HOME/Library/Application Support/VMDeck/autostart.list"
    LOG="$HOME/Library/Logs/VMDeck/autostart.log"
    mkdir -p "$(dirname "$LOG")"
    exec >>"$LOG" 2>&1
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') auto-start begins"
    [ -f "$LIST" ] || { echo "no list at $LIST, nothing to do"; exit 0; }
    { read -r WAIT STAGGER; read -r VMRUN; } < "$LIST"
    : "${WAIT:=600}" "${STAGGER:=15}"
    [ -n "$VMRUN" ] || { echo "list has no vmrun path"; exit 1; }
    # Fusion itself may live on a slow volume, or not be installed yet.
    waited=0
    while [ ! -x "$VMRUN" ] && [ "$waited" -lt "$WAIT" ]; do sleep 5; waited=$((waited + 5)); done
    [ -x "$VMRUN" ] || { echo "vmrun not found at $VMRUN after ${WAIT}s, giving up"; exit 1; }
    first=1
    tail -n +3 "$LIST" | while IFS= read -r vmx; do
      [ -n "$vmx" ] || continue
      name=$(basename "$vmx" .vmx)
      waited=0
      while [ ! -f "$vmx" ] && [ "$waited" -lt "$WAIT" ]; do
        [ "$waited" -eq 0 ] && echo "$name: waiting for $vmx (volume not mounted yet?)"
        sleep 5; waited=$((waited + 5))
      done
      if [ ! -f "$vmx" ]; then echo "$name: still missing after ${WAIT}s, skipped"; continue; fi
      if "$VMRUN" -T fusion list 2>/dev/null | grep -qxF "$vmx"; then echo "$name: already running"; continue; fi
      if [ "$first" -eq 0 ] && [ "$STAGGER" -gt 0 ]; then sleep "$STAGGER"; fi
      first=0
      echo "$name: starting"
      # Output goes to a file, not $(…): vmware-vmx inherits vmrun's stdout
      # and would hold a pipe open until the VM stops.
      tmp=$(mktemp -t vmdeck-autostart) || tmp=/dev/null
      "$VMRUN" -T fusion start "$vmx" nogui >"$tmp" 2>&1 </dev/null
      rc=$?
      if [ "$rc" -eq 0 ]; then echo "$name: started"; else echo "$name: FAILED: $(cat "$tmp" 2>/dev/null | tr '\n' ' ')"; fi
      [ "$tmp" != /dev/null ] && rm -f "$tmp"
    done
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') auto-start done"
    """#

    /// $1 vmrun path, $2 wait, $3 stagger, $4 "1" to touch launchctl (tests
    /// pass 0), $5 the runner script text, then the .vmx paths. No paths:
    /// uninstall. Installing never loads the agent: with RunAtLoad that
    /// would start every listed VM the moment the user clicks Save. macOS
    /// loads it at the next login, and Run Now covers testing.
    static let installScript = #"""
    VMRUN=$1 WAIT=$2 STAGGER=$3 LAUNCHCTL=$4 RUNNER=$5; shift 5
    LABEL="com.vantine.vmdeck.autostart"
    DIR="$HOME/Library/Application Support/VMDeck"
    LIST="$DIR/autostart.list"; SCRIPT="$DIR/autostart.sh"
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    UID_=$(id -u)
    unload() { [ "$LAUNCHCTL" = 1 ] && launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1; return 0; }
    if [ $# -eq 0 ]; then
      unload; rm -f "$PLIST" "$LIST" "$SCRIPT"
      echo "OK\tuninstalled"; exit 0
    fi
    mkdir -p "$DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/VMDeck" || { printf 'ERR\tCannot write to %s\n' "$DIR"; exit 0; }
    { printf '%s %s\n%s\n' "$WAIT" "$STAGGER" "$VMRUN"; for p in "$@"; do printf '%s\n' "$p"; done; } > "$LIST"
    printf '%s\n' "$RUNNER" > "$SCRIPT"
    chmod 755 "$SCRIPT"
    cat > "$PLIST" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    	<key>Label</key>
    	<string>$LABEL</string>
    	<key>ProgramArguments</key>
    	<array>
    		<string>/bin/sh</string>
    		<string>$SCRIPT</string>
    	</array>
    	<key>RunAtLoad</key>
    	<true/>
    	<key>ProcessType</key>
    	<string>Background</string>
    </dict>
    </plist>
    EOF
    plutil -lint "$PLIST" >/dev/null || { printf 'ERR\tWrote an invalid LaunchAgent plist\n'; exit 0; }
    if [ "$LAUNCHCTL" = 1 ] && launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; then
      echo "OK\tupdated (already loaded)"
    else
      echo "OK\tinstalled (loads at next login)"
    fi
    """#

    static let statusScript = #"""
    LABEL="com.vantine.vmdeck.autostart"
    DIR="$HOME/Library/Application Support/VMDeck"
    LIST="$DIR/autostart.list"; PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    LOG="$HOME/Library/Logs/VMDeck/autostart.log"
    [ -f "$PLIST" ] && echo "INSTALLED\t1" || echo "INSTALLED\t0"
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "LOADED\t1" || echo "LOADED\t0"
    if [ -f "$LIST" ]; then
      read -r w s < "$LIST"; printf 'WAIT\t%s\nSTAGGER\t%s\n' "$w" "$s"
      tail -n +3 "$LIST" | while IFS= read -r p; do [ -n "$p" ] && printf 'VM\t%s\n' "$p"; done
    fi
    printf 'CONSOLE\t%s\n' "$(stat -f %Su /dev/console 2>/dev/null)"
    printf 'AUTOLOGIN\t%s\n' "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)"
    [ -f "$LOG" ] && tail -n 25 "$LOG" | sed 's/^/LOG\t/'
    exit 0
    """#

    static let runNowScript = #"""
    LABEL="com.vantine.vmdeck.autostart"
    SCRIPT="$HOME/Library/Application Support/VMDeck/autostart.sh"
    [ -f "$SCRIPT" ] || { printf 'ERR\tAuto-start is not installed on this host.\n'; exit 0; }
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      launchctl kickstart -k "gui/$(id -u)/$LABEL" && echo "OK\tkickstarted" && exit 0
    fi
    # Not loaded (no GUI session for launchd to use): run it directly.
    nohup /bin/sh "$SCRIPT" >/dev/null 2>&1 </dev/null &
    echo "OK\tstarted directly"
    """#
}
