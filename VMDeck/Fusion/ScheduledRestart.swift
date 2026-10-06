import Foundation

/// When a VM restarts on its own: a time of day on chosen weekdays, in the
/// host's local time.
struct RestartSchedule: Equatable, Sendable {
    var hour: Int = 3
    var minute: Int = 0
    /// 0 = Sunday … 6 = Saturday, as launchd counts them.
    var weekdays: Set<Int> = Set(0...6)
    var enabled = true
    /// What the schedule does at that time.
    enum Method: String, CaseIterable, Sendable {
        /// Ask the guest to restart through Tools; the host process stays.
        case reboot
        /// Suspend and resume: a fresh host process, no guest reboot.
        case suspend
        /// Shut down and start: a fresh host process and a guest boot.
        case cycle

        var label: String {
            switch self {
            case .reboot: "Restart the guest"
            case .suspend: "Suspend and resume"
            case .cycle: "Power cycle the VM"
            }
        }

        var verb: String {
            switch self {
            case .reboot: "Restarts"
            case .suspend: "Suspends and resumes"
            case .cycle: "Power cycles"
            }
        }

        var noun: String {
            switch self {
            case .reboot: "restart"
            case .suspend: "suspend and resume"
            case .cycle: "power cycle"
            }
        }
    }

    var method: Method = .reboot

    var verb: String { method.verb }

    static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var timeLabel: String { String(format: "%d:%02d", hour, minute) }

    /// "Daily at 3:00", "Sun at 3:00", "Mon, Wed, Fri at 3:00".
    var label: String {
        let days: String
        switch weekdays {
        case Set(0...6): days = "Daily"
        case Set(1...5): days = "Weekdays"
        case [0, 6]: days = "Weekends"
        case let w where w.isEmpty: return "Never"
        default: days = weekdays.sorted().map { Self.dayNames[$0] }.joined(separator: ", ")
        }
        return "\(days) at \(timeLabel)"
    }

    /// `label` for mid-sentence use: "daily at 3:00", but "Sun at 4:30".
    var sentenceLabel: String {
        let l = label
        return ["Daily", "Weekdays", "Weekends", "Never"].contains(where: { l.hasPrefix($0) }) ? l.lowercased() : l
    }

    /// The next time this fires after `date`, in `calendar`'s time zone.
    /// It's a preview: the host's launchd decides for real, in its own zone.
    func nextRun(after date: Date = .now, calendar: Calendar = .current) -> Date? {
        guard enabled, !weekdays.isEmpty else { return nil }
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            let weekday = calendar.component(.weekday, from: candidate) - 1
            if weekdays.contains(weekday), candidate > date { return candidate }
        }
        return nil
    }
}

struct ScheduledRestartStatus: Equatable, Sendable {
    /// Every VM on the host with a saved schedule (enabled or not).
    var schedules: [String: RestartSchedule] = [:]
    /// Which of those launchd currently has loaded.
    var loaded: Set<String> = []
    /// How long a scheduled restart lets the guest shut down before pulling the plug.
    var shutdownWaitSeconds = 600
    var recentLog = ""
}

/// Installs per-VM LaunchAgents on a host that restart VMs on a calendar.
///
/// Each enabled schedule becomes `com.vantine.vmdeck.restart.<id>.plist` with
/// `StartCalendarInterval` entries, running `restart.sh <vmx>`. The script
/// asks the guest to restart (`vmrun reset soft`); if the guest can't, it
/// shuts down (bounded wait, then Power Off) and starts headless again.
struct ScheduledRestartManager: Sendable {
    let vmrun: VMRun

    static let labelPrefix = "com.vantine.vmdeck.restart."

    /// A stable, filename-safe id for a .vmx path.
    static func id(for vmxPath: String) -> String {
        // cksum-compatible so the shell side can compute the same id.
        var crc: UInt32 = 0
        var length = 0
        for byte in vmxPath.utf8 {
            crc = Self.crcStep(crc, byte)
            length += 1
        }
        var n = length
        while n != 0 {
            crc = Self.crcStep(crc, UInt8(n & 0xFF))
            n >>= 8
        }
        return String(~crc & 0xFFFF_FFFF)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = (c & 0x8000_0000) != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }

    private static func crcStep(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(byte))]
    }

    func status() async throws -> ScheduledRestartStatus {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.statusScript, "vmdeck-restart-status"],
                                                timeout: .seconds(20))
        try VMRun.check(result)
        return Self.parseStatus(result.stdout)
    }

    /// Rewrites every schedule on the host. Agents for enabled schedules are
    /// loaded right away; StartCalendarInterval doesn't fire on load, so
    /// nothing restarts until its time.
    func install(_ schedules: [String: RestartSchedule], shutdownWaitSeconds: Int) async throws {
        var argv = ["/bin/sh", "-c", Self.installScript, "vmdeck-restart-install",
                    vmrun.vmrunPath, String(shutdownWaitSeconds), "1", Self.runnerScript]
        for (path, s) in schedules.sorted(by: { $0.key < $1.key }) {
            argv += [String(s.hour), String(s.minute), s.weekdays.sorted().map(String.init).joined(separator: ","),
                     s.enabled ? "1" : "0", s.method.rawValue, path]
        }
        let result = try await vmrun.runner.run(argv, timeout: .seconds(60))
        try VMRun.check(result)
    }

    /// Restarts the VM now, the way its schedule would.
    func restartNow(_ vmxPath: String) async throws {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.runNowScript, "vmdeck-restart-now", vmxPath],
                                                timeout: .seconds(20))
        try VMRun.check(result)
    }

    static func parseStatus(_ output: String) -> ScheduledRestartStatus {
        var status = ScheduledRestartStatus()
        var log: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f[0] {
            case "WAIT" where f.count >= 2:
                status.shutdownWaitSeconds = Int(f[1]) ?? status.shutdownWaitSeconds
            case "SCHED" where f.count >= 7:
                let days = Set(f[3].split(separator: ",").compactMap { Int($0) }.filter { (0...6).contains($0) })
                status.schedules[f[6]] = RestartSchedule(hour: Int(f[1]) ?? 0, minute: Int(f[2]) ?? 0,
                                                         weekdays: days, enabled: f[4] == "1",
                                                         method: RestartSchedule.Method(rawValue: f[5]) ?? .reboot)
            case "LOADED" where f.count >= 2:
                status.loaded.insert(f[1])
            case "LOG":
                log.append(f.dropFirst().joined(separator: "\t"))
            default:
                continue
            }
        }
        status.recentLog = log.joined(separator: "\n")
        return status
    }

    // MARK: - Host-side scripts

    /// `restart.sh <vmx>`. restart.list line 1 is the vmrun path, line 2 the
    /// shutdown wait in seconds; the rest is the schedule table.
    static let runnerScript = #"""
    #!/bin/sh
    # Written by VMDeck. Restarts one VM: asks the guest to restart; if it
    # can't, shuts the VM down (waiting a bounded time, then powering off)
    # and starts it headless again. Edit schedules in VMDeck, not here.
    """# + "\n" + PendingSettingsManager.applyFunction + "\n" + #"""
    vmx=$1
    LIST="$HOME/Library/Application Support/VMDeck/restart.list"
    LOG="$HOME/Library/Logs/VMDeck/restart.log"
    mkdir -p "$(dirname "$LOG")"
    exec >>"$LOG" 2>&1
    name=$(basename "$vmx" .vmx)
    stamp() { date '+%Y-%m-%d %H:%M:%S'; }
    [ -n "$vmx" ] || { echo "$(stamp) no VM given"; exit 1; }
    { read -r VMRUN; read -r WAIT; } < "$LIST"
    : "${WAIT:=600}"
    [ -x "$VMRUN" ] || { echo "$(stamp) $name: vmrun not found at $VMRUN"; exit 1; }
    running() { "$VMRUN" -T fusion list 2>/dev/null | grep -qxF "$vmx"; }
    # Records are: hour minute days enabled [mode] vmx; mode is "cycle" or "reboot".
    mode=$(awk -F'\t' -v v="$vmx" 'NR > 2 && $NF == v { print (NF >= 6 ? $5 : "reboot") }' "$LIST" | tail -1)
    tmp=$(mktemp -t vmdeck-restart) || exit 1
    trap 'rm -f "$tmp"' EXIT
    case $mode in
      cycle) echo "$(stamp) $name: scheduled power cycle" ;;
      suspend) echo "$(stamp) $name: scheduled suspend and resume" ;;
      *) echo "$(stamp) $name: scheduled restart" ;;
    esac
    if ! running; then echo "$(stamp) $name: not running, skipped"; exit 0; fi
    # Output to a file, never $(…): vmware-vmx holds vmrun's stdout open.
    if [ "$mode" = suspend ]; then
      # A suspend ends the host process; resuming starts a fresh one with the
      # guest exactly where it was. No guest reboot, so no boot-time trouble.
      if ! "$VMRUN" -T fusion suspend "$vmx" hard >"$tmp" 2>&1 </dev/null; then
        echo "$(stamp) $name: SUSPEND FAILED: $(tr '\n' ' ' <"$tmp")"; exit 1
      fi
      echo "$(stamp) $name: suspended"
      sleep 3
      if "$VMRUN" -T fusion start "$vmx" nogui >"$tmp" 2>&1 </dev/null; then
        echo "$(stamp) $name: resumed"; exit 0
      fi
      echo "$(stamp) $name: RESUME FAILED: $(tr '\n' ' ' <"$tmp")"; exit 1
    fi
    if [ "$mode" != cycle ]; then
      if "$VMRUN" -T fusion reset "$vmx" soft >"$tmp" 2>&1 </dev/null; then
        echo "$(stamp) $name: guest restarted"; exit 0
      fi
      echo "$(stamp) $name: guest can't restart itself ($(tr '\n' ' ' <"$tmp")); shutting down instead"
    else
      echo "$(stamp) $name: shutting down for a fresh VM process"
    fi
    "$VMRUN" -T fusion stop "$vmx" soft >"$tmp" 2>&1 </dev/null &
    stopper=$!
    waited=0
    while kill -0 "$stopper" 2>/dev/null && [ "$waited" -lt "$WAIT" ]; do sleep 5; waited=$((waited + 5)); done
    if running; then
      echo "$(stamp) $name: still running after ${WAIT}s, powering off"
      kill "$stopper" 2>/dev/null
      "$VMRUN" -T fusion stop "$vmx" hard >"$tmp" 2>&1 </dev/null
    else
      echo "$(stamp) $name: shut down cleanly"
    fi
    sleep 3
    # Settings queued in <vmx>.vmdeck-pending (key = "value" lines) go in now,
    # while the VM is off: Fusion rewrites the .vmx at power-off, so edits made
    # while it ran would have been lost.
    if ! running; then
      vmdeck_apply_pending "$vmx" | while IFS= read -r l; do echo "$(stamp) $name: applied setting $l"; done
    fi
    if "$VMRUN" -T fusion start "$vmx" nogui >"$tmp" 2>&1 </dev/null; then
      echo "$(stamp) $name: started"
    else
      echo "$(stamp) $name: START FAILED: $(tr '\n' ' ' <"$tmp")"; exit 1
    fi
    """#

    /// $1 vmrun, $2 shutdown wait, $3 "1" to touch launchctl, $4 runner text,
    /// then records of 6: hour minute days enabled mode vmx. Rewrites everything.
    static let installScript = #"""
    VMRUN=$1 WAIT=$2 LAUNCHCTL=$3 RUNNER=$4; shift 4
    PREFIX="com.vantine.vmdeck.restart."
    DIR="$HOME/Library/Application Support/VMDeck"
    LIST="$DIR/restart.list"; SCRIPT="$DIR/restart.sh"
    AGENTS="$HOME/Library/LaunchAgents"
    UID_=$(id -u)
    mkdir -p "$DIR" "$AGENTS" "$HOME/Library/Logs/VMDeck" || { printf 'ERR\tCannot write to %s\n' "$DIR"; exit 0; }
    for old in "$AGENTS/$PREFIX"*.plist; do
      [ -f "$old" ] || continue
      label=$(basename "$old" .plist)
      [ "$LAUNCHCTL" = 1 ] && launchctl bootout "gui/$UID_/$label" >/dev/null 2>&1
      rm -f "$old"
    done
    { printf '%s\n%s\n' "$VMRUN" "$WAIT"
      while [ $# -ge 6 ]; do printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"; shift 6; done; } > "$LIST"
    printf '%s\n' "$RUNNER" > "$SCRIPT"; chmod 755 "$SCRIPT"
    count=0
    tail -n +3 "$LIST" | while IFS="$(printf '\t')" read -r hour minute days enabled mode vmx; do
      [ "$enabled" = 1 ] && [ -n "$days" ] || continue
      id=$(printf '%s' "$vmx" | cksum | cut -d' ' -f1)
      plist="$AGENTS/$PREFIX$id.plist"
      {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
        printf '\t<key>Label</key>\n\t<string>%s%s</string>\n' "$PREFIX" "$id"
        printf '\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/bin/sh</string>\n\t\t<string>%s</string>\n\t\t<string>%s</string>\n\t</array>\n' "$SCRIPT" "$(printf '%s' "$vmx" | sed 's/&/\&amp;/g; s/</\&lt;/g')"
        printf '\t<key>StartCalendarInterval</key>\n\t<array>\n'
        # printf with a trailing newline: `read` drops a last line that lacks one.
        printf '%s\n' "$days" | tr ',' '\n' | while read -r d; do
          [ -n "$d" ] && printf '\t\t<dict>\n\t\t\t<key>Hour</key><integer>%s</integer>\n\t\t\t<key>Minute</key><integer>%s</integer>\n\t\t\t<key>Weekday</key><integer>%s</integer>\n\t\t</dict>\n' "$hour" "$minute" "$d"
        done
        printf '\t</array>\n\t<key>ProcessType</key>\n\t<string>Background</string>\n</dict>\n</plist>\n'
      } > "$plist"
      plutil -lint "$plist" >/dev/null || { printf 'ERR\tWrote an invalid plist for %s\n' "$(basename "$vmx")"; exit 0; }
      [ "$LAUNCHCTL" = 1 ] && launchctl bootstrap "gui/$UID_" "$plist" >/dev/null 2>&1
      count=$((count + 1))
      printf 'OK\tscheduled %s\n' "$(basename "$vmx" .vmx)"
    done
    exit 0
    """#

    static let statusScript = #"""
    PREFIX="com.vantine.vmdeck.restart."
    LIST="$HOME/Library/Application Support/VMDeck/restart.list"
    LOG="$HOME/Library/Logs/VMDeck/restart.log"
    if [ -f "$LIST" ]; then
      { read -r _; read -r w; } < "$LIST"; printf 'WAIT\t%s\n' "$w"
      tail -n +3 "$LIST" | while IFS="$(printf '\t')" read -r hour minute days enabled mode vmx; do
        [ -z "$vmx" ] && { vmx=$mode; mode=reboot; }   # lists written before the mode field
        [ -n "$vmx" ] && printf 'SCHED\t%s\t%s\t%s\t%s\t%s\t%s\n' "$hour" "$minute" "$days" "$enabled" "$mode" "$vmx"
      done
    fi
    for p in "$HOME/Library/LaunchAgents/$PREFIX"*.plist; do
      [ -f "$p" ] || continue
      label=$(basename "$p" .plist)
      launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && printf 'LOADED\t%s\n' "${label#$PREFIX}"
    done
    [ -f "$LOG" ] && tail -n 40 "$LOG" | sed 's/^/LOG\t/'
    exit 0
    """#

    static let runNowScript = #"""
    SCRIPT="$HOME/Library/Application Support/VMDeck/restart.sh"
    [ -f "$SCRIPT" ] || { printf 'ERR\tNo restart script on this host yet. Save a schedule first.\n'; exit 0; }
    nohup /bin/sh "$SCRIPT" "$1" >/dev/null 2>&1 </dev/null &
    echo "OK\tstarted"
    """#
}
