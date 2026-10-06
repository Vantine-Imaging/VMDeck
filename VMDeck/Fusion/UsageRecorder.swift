import Foundation

/// One averaged bucket of a VM's resource use.
struct UsageSample: Identifiable, Equatable, Sendable {
    let date: Date
    /// Host-core percent, as `ps` reports it (a 6-vCPU VM can reach 600).
    let cpuPercent: Double
    let residentBytes: Int64
    var id: Date { date }
}

/// One averaged bucket of the host's load and memory.
struct HostSample: Identifiable, Equatable, Sendable {
    let date: Date
    let load1: Double
    let memoryUsedBytes: Int64
    let swapUsedBytes: Int64
    var id: Date { date }
}

struct UsageSeries: Equatable, Sendable {
    var vm: [UsageSample] = []
    var host: [HostSample] = []
    /// The recorder's LaunchAgent is installed on the host.
    var recording = false
    /// launchd has it loaded right now.
    var loaded = false
    /// Oldest sample on disk.
    var since: Date?
}

/// How far back a chart looks, and how coarse its buckets are.
enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week, month
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: "1 hour"
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    var seconds: Int {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    /// About 60 to 360 points per chart.
    var bucketSeconds: Int {
        switch self {
        case .hour: 60
        case .day: 300
        case .week: 1800
        case .month: 7200
        }
    }
}

/// A once-a-minute sampler on the host, installed as a per-user LaunchAgent,
/// that appends each VM process's CPU and memory and the host's load and
/// memory to monthly files. VMDeck isn't always running, so the host keeps
/// the record. Three months are kept.
struct UsageRecorderManager: Sendable {
    let vmrun: VMRun

    static let label = "com.vantine.vmdeck.usage"

    func series(for vmxPath: String?, range: UsageRange, now: Date = .now) async throws -> UsageSeries {
        let since = Int(now.timeIntervalSince1970) - range.seconds
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.queryScript, "vmdeck-usage-query",
                                                 vmxPath ?? "", String(since), String(range.bucketSeconds)],
                                                timeout: .seconds(60))
        try VMRun.check(result)
        return Self.parse(result.stdout)
    }

    /// Installs (and loads) or removes the recorder. Data stays either way.
    func setRecording(_ on: Bool) async throws {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.installScript, "vmdeck-usage-install",
                                                 on ? "1" : "0", "1", Self.samplerScript],
                                                timeout: .seconds(30))
        try VMRun.check(result)
    }

    static func parse(_ output: String) -> UsageSeries {
        var s = UsageSeries()
        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f[0] {
            case "V" where f.count >= 4:
                guard let t = Double(f[1]), let cpu = Double(f[2]), let rss = Double(f[3]) else { continue }
                s.vm.append(UsageSample(date: Date(timeIntervalSince1970: t), cpuPercent: cpu, residentBytes: Int64(rss)))
            case "H" where f.count >= 5:
                guard let t = Double(f[1]), let load = Double(f[2]), let mem = Double(f[3]), let swap = Double(f[4]) else { continue }
                s.host.append(HostSample(date: Date(timeIntervalSince1970: t), load1: load,
                                         memoryUsedBytes: Int64(mem), swapUsedBytes: Int64(swap)))
            case "REC" where f.count >= 3:
                s.recording = f[1] == "1"
                s.loaded = f[2] == "1"
            case "SINCE" where f.count >= 2:
                if let t = Double(f[1]) { s.since = Date(timeIntervalSince1970: t) }
            default:
                continue
            }
        }
        s.vm.sort { $0.date < $1.date }
        s.host.sort { $0.date < $1.date }
        return s
    }

    // MARK: - Host-side scripts

    /// `usage.sh`: one sample. Lines are `ts  VM  <vmx>  <pcpu>  <rssKB>` and
    /// `ts  HOST  <load1>  <usedBytes>  <swapUsedBytes>`, appended to
    /// `~/Library/Logs/VMDeck/usage/YYYY-MM.tsv`.
    static let samplerScript = #"""
    #!/bin/sh
    # Written by VMDeck. Records each VM's CPU and memory and the host's load
    # and memory once a minute. Turn it off in VMDeck (Usage History).
    DIR="$HOME/Library/Logs/VMDeck/usage"
    mkdir -p "$DIR" || exit 0
    ts=$(date +%s)
    file="$DIR/$(date +%Y-%m).tsv"
    {
      ps -Ao pcpu=,rss=,args= | grep "Library/vmware-vmx " | sed -nE 's#^ *([0-9.]+) +([0-9]+) .*[[:space:]](/.*\.vmx)$#\3\t\1\t\2#p' |
        while IFS="$(printf '\t')" read -r vmx cpu rss; do printf '%s\tVM\t%s\t%s\t%s\n' "$ts" "$vmx" "$cpu" "$rss"; done
      load=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{ print $1 }')
      used=$(vm_stat | awk '
        /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
        /^Pages (active|wired down|occupied by compressor):/ { v = $NF; sub(/\./, "", v); used += v }
        END { printf "%.0f", used * ps }')
      swap=$(sysctl -n vm.swapusage | sed -nE 's/.*used = ([0-9.]+)M.*/\1/p' | awk '{ printf "%.0f", $1 * 1048576 }')
      printf '%s\tHOST\t%s\t%s\t%s\n' "$ts" "$load" "$used" "${swap:-0}"
    } >> "$file"
    # Keep three months.
    keep1=$(date +%Y-%m); keep2=$(date -v-1m +%Y-%m); keep3=$(date -v-2m +%Y-%m)
    for f in "$DIR"/*.tsv; do
      [ -f "$f" ] || continue
      case $(basename "$f" .tsv) in "$keep1"|"$keep2"|"$keep3") ;; *) rm -f "$f" ;; esac
    done
    """#

    /// $1 "1" to install or "0" to remove, $2 "1" to touch launchctl, $3 the
    /// sampler text.
    static let installScript = #"""
    ON=$1 LAUNCHCTL=$2 SAMPLER=$3
    LABEL="com.vantine.vmdeck.usage"
    DIR="$HOME/Library/Application Support/VMDeck"
    SCRIPT="$DIR/usage.sh"; PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    UID_=$(id -u)
    if [ "$ON" != 1 ]; then
      [ "$LAUNCHCTL" = 1 ] && launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1
      rm -f "$PLIST" "$SCRIPT"
      echo "OK\tstopped"; exit 0
    fi
    mkdir -p "$DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/VMDeck/usage" || { printf 'ERR\tCannot write to %s\n' "$DIR"; exit 0; }
    printf '%s\n' "$SAMPLER" > "$SCRIPT"; chmod 755 "$SCRIPT"
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
    	<key>StartInterval</key>
    	<integer>60</integer>
    	<key>RunAtLoad</key>
    	<true/>
    	<key>ProcessType</key>
    	<string>Background</string>
    	<key>LowPriorityIO</key>
    	<true/>
    </dict>
    </plist>
    EOF
    plutil -lint "$PLIST" >/dev/null || { printf 'ERR\tWrote an invalid LaunchAgent plist\n'; exit 0; }
    if [ "$LAUNCHCTL" = 1 ]; then
      launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1
      launchctl bootstrap "gui/$UID_" "$PLIST" >/dev/null 2>&1 && echo "OK\trecording" && exit 0
      echo "OK\tinstalled (starts at next login)"
    else
      echo "OK\tinstalled"
    fi
    """#

    /// $1 vmx path (empty for host only), $2 since (epoch), $3 bucket seconds.
    /// Averages each bucket on the host so only the points cross the wire.
    static let queryScript = #"""
    VMX=$1 SINCE=$2 BUCKET=$3
    LABEL="com.vantine.vmdeck.usage"
    DIR="$HOME/Library/Logs/VMDeck/usage"
    [ -f "$HOME/Library/LaunchAgents/$LABEL.plist" ] && rec=1 || rec=0
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && loaded=1 || loaded=0
    printf 'REC\t%s\t%s\n' "$rec" "$loaded"
    [ -d "$DIR" ] || exit 0
    first=$(ls "$DIR"/*.tsv 2>/dev/null | sort | head -1)
    [ -n "$first" ] && printf 'SINCE\t%s\n' "$(head -1 "$first" | cut -f1)"
    from=$(date -r "$SINCE" +%Y-%m 2>/dev/null || echo 0000-00)
    for f in "$DIR"/*.tsv; do
      [ -f "$f" ] || continue
      [ "$(basename "$f" .tsv)" \< "$from" ] && continue
      cat "$f"
    done | awk -F'\t' -v vmx="$VMX" -v since="$SINCE" -v b="$BUCKET" '
      $1 >= since {
        t = int($1 / b) * b
        if ($2 == "VM" && $3 == vmx) { vc[t]++; vcpu[t] += $4; vrss[t] += $5 }
        else if ($2 == "HOST") { hc[t]++; hl[t] += $3; hm[t] += $4; hs[t] += $5 }
      }
      END {
        for (t in vc) printf "V\t%d\t%.2f\t%.0f\n", t, vcpu[t] / vc[t], vrss[t] / vc[t] * 1024
        for (t in hc) printf "H\t%d\t%.2f\t%.0f\t%.0f\n", t, hl[t] / hc[t], hm[t] / hc[t], hs[t] / hc[t]
      }'
    exit 0
    """#
}
