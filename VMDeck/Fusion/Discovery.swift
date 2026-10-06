import Foundation

/// Settings read from a VM's .vmx.
struct VMConfig: Equatable, Sendable {
    var vcpus: Int?
    var memoryMB: Int?
    var guestOS: String?
    /// Normalized: lowercase, two hex digits per octet.
    var macAddresses: [String] = []
}

/// The host-side `vmware-vmx` process of a running VM.
struct VMProcessStats: Equatable, Sendable {
    var pid: Int
    /// ps %CPU: 100 means one host core fully busy.
    var cpuPercent: Double
    var residentBytes: Int64
    var uptime: TimeInterval

    /// CPU as a share of the VM's own vCPUs, 0–100 (a 6-vCPU VM at 362% is
    /// 60%). Can briefly exceed 100 from host-side overhead, so it's clamped.
    func cpuShare(vcpus: Int?) -> Double {
        min(cpuPercent / Double(max(vcpus ?? 1, 1)), 100)
    }
}

/// The volume a VM's files live on.
struct VolumeStats: Equatable, Sendable {
    var mountPoint: String
    var totalBytes: Int64
    var availableBytes: Int64
}

struct HostStats: Equatable, Sendable {
    var model: String
    var osVersion: String
    var cpuCount: Int
    var memoryBytes: Int64
    var memoryUsedBytes: Int64?
    var loadAverage: [Double]
    var bootTime: Date?
}

/// A lifecycle command already running on the host, from VMDeck (possibly an
/// earlier run of it) or anything else that uses vmrun.
struct PendingOperation: Equatable, Sendable {
    enum Kind: String, Sendable {
        case start, stop, suspend, reset
    }
    var kind: Kind
    /// For stop and reset: "hard" was requested.
    var hard: Bool
    var startedAt: Date
}

struct DiscoveredVM: Equatable, Sendable {
    let vmxPath: String
    let displayName: String
    let powerState: PowerState
    var config = VMConfig()
    var process: VMProcessStats?
    var volume: VolumeStats?
    var pending: PendingOperation?
    /// The address VMware Tools published (guestinfo.ip), if it's a real one.
    var guestIP: String?
    var tools: ToolsState?
    var autoStart = false
    var restartSchedule: RestartSchedule?
}

/// Finds every VM on a host, stopped ones included, plus live stats, in one
/// round trip.
///
/// `vmrun list` only knows about running VMs, so a shell script on the host
/// also scans the default VM folders (per-user and /Users/Shared), Fusion's
/// library inventory, and any paths the user added. All paths are
/// canonicalized there (`pwd -P`) so the same VM reached two ways shows up once.
struct Discovery: Sendable {
    let vmrun: VMRun

    struct Result: Equatable, Sendable {
        var vms: [DiscoveredVM] = []
        var host: HostStats?
        /// MAC → IP from the host's ARP table and Fusion's DHCP leases. Used
        /// for guests whose VMware Tools can't report an address.
        var neighbors: [String: String] = [:]
        var error: String?
    }

    func discover(extraPaths: [String] = []) async throws -> Result {
        let argv = ["/bin/sh", "-c", Self.script, "vmdeck-discover", vmrun.vmrunPath] + extraPaths
        let result = try await vmrun.runner.run(argv, timeout: .seconds(20))
        let parsed = Self.parse(result.stdout)
        if let error = parsed.error { throw VMRunError.vmrun(error) }
        if result.status != 0 {
            try VMRun.check(result)
        }
        return parsed
    }

    /// Output lines are tab-separated records:
    ///   RUN   <path>                                        running VM
    ///   VM    <path> <name> <0|1 suspended> <vcpus> <memMB> <guestOS> <mac,mac,>
    ///   PS    <pid> <%cpu> <rssKB> <etime> <args…>          a vmware-vmx process
    ///   DF    <path> <totalKB> <availKB> <mount point>      volume holding a VM
    ///   HOST  <ncpu> <memBytes> <load1,5,15> <bootSec> <model> <osVersion>
    ///   MEM   <usedBytes>
    ///   NET   <ip> <mac>                                    lease or ARP entry
    ///   OP    <etime> <args…>                               a running vmrun command
    ///   GUEST <path> <ip> <toolsState>                      Tools' published IP, per running VM
    ///   AUTO  <path>                                        in the host's auto-start list
    ///   SCHED <hour> <minute> <days> <enabled> <mode> <path>  a saved restart schedule (mode: reboot|cycle)
    ///   ERR   <message>
    static func parse(_ output: String) -> Result {
        var running = Set<String>()
        var seen = Set<String>()
        var records: [(path: String, name: String, suspended: Bool, config: VMConfig)] = []
        var processes: [(args: String, stats: VMProcessStats)] = []
        var volumes: [String: VolumeStats] = [:]
        var operations: [(args: String, elapsed: TimeInterval)] = []
        var guests: [String: (ip: String, tools: String)] = [:]
        var autoStart = Set<String>()
        var schedules: [String: RestartSchedule] = [:]
        var result = Result()
        let now = Date.now

        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
            switch f.first {
            case "ERR":
                result.error = f.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            case "RUN" where f.count >= 2:
                running.insert(f[1])
            case "VM" where f.count >= 4:
                guard seen.insert(f[1]).inserted else { continue }
                let config = VMConfig(
                    vcpus: Int(field(4)),
                    memoryMB: Int(field(5)),
                    guestOS: field(6).isEmpty ? nil : field(6),
                    macAddresses: field(7).split(separator: ",").compactMap { normalizeMAC(String($0)) })
                records.append((f[1], f[2], f[3] == "1", config))
            case "PS" where f.count >= 6:
                guard let pid = Int(f[1]), let cpu = Double(f[2]), let rss = Int64(f[3]) else { continue }
                let stats = VMProcessStats(pid: pid, cpuPercent: cpu, residentBytes: rss * 1024,
                                           uptime: parseElapsed(f[4]) ?? 0)
                processes.append((f[5...].joined(separator: "\t"), stats))
            case "DF" where f.count >= 5:
                guard let total = Int64(f[2]), let avail = Int64(f[3]) else { continue }
                volumes[f[1]] = VolumeStats(mountPoint: f[4], totalBytes: total * 1024, availableBytes: avail * 1024)
            case "HOST" where f.count >= 7:
                result.host = HostStats(
                    model: f[5], osVersion: f[6],
                    cpuCount: Int(f[1]) ?? 0,
                    memoryBytes: Int64(f[2]) ?? 0,
                    loadAverage: f[3].split(separator: ",").compactMap { Double($0) },
                    bootTime: TimeInterval(f[4]).map { Date(timeIntervalSince1970: $0) })
            case "MEM" where f.count >= 2:
                result.host?.memoryUsedBytes = Int64(f[1])
            case "GUEST" where f.count >= 4:
                guests[f[1]] = (f[2], f[3])
            case "AUTO" where f.count >= 2:
                autoStart.insert(f[1])
            case "SCHED" where f.count >= 7:
                let days = Set(f[3].split(separator: ",").compactMap { Int($0) }.filter { (0...6).contains($0) })
                schedules[f[6]] = RestartSchedule(hour: Int(f[1]) ?? 0, minute: Int(f[2]) ?? 0,
                                                  weekdays: days, enabled: f[4] == "1",
                                                  method: RestartSchedule.Method(rawValue: f[5]) ?? .reboot)
            case "OP" where f.count >= 3:
                operations.append((f[2...].joined(separator: "\t"), parseElapsed(f[1]) ?? 0))
            case "NET" where f.count >= 3:
                // Later lines win: the script prints leases first, then ARP.
                if let mac = normalizeMAC(f[2]) { result.neighbors[mac] = f[1] }
            default:
                continue
            }
        }

        result.vms = records.map { record in
            let state: PowerState =
                running.contains(record.path) ? .running : record.suspended ? .suspended : .stopped
            let fallback = URL(fileURLWithPath: record.path).deletingPathExtension().lastPathComponent
            var vm = DiscoveredVM(
                vmxPath: record.path,
                displayName: record.name.isEmpty ? fallback : record.name,
                powerState: state,
                config: record.config,
                volume: volumes[record.path],
                autoStart: autoStart.contains(record.path),
                restartSchedule: schedules[record.path])
            // vmware-vmx takes the .vmx path as its last argument.
            if state == .running {
                vm.process = processes.first { $0.args.hasSuffix(record.path) }?.stats
                if let guest = guests[record.path] {
                    vm.guestIP = VMRun.isIPAddress(guest.ip) ? guest.ip : nil
                    // A published address is proof Tools is alive, whatever
                    // vmrun's own handshake flag says.
                    vm.tools = vm.guestIP != nil ? .running : ToolsState(vmrunWord: guest.tools)
                }
            }
            vm.pending = operations.lazy.compactMap { op in
                parseOperation(op.args, vmx: record.path).map {
                    PendingOperation(kind: $0.kind, hard: $0.hard, startedAt: now.addingTimeInterval(-op.elapsed))
                }
            }.first
            return vm
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return result
    }

    /// Recognizes `…/vmrun -T fusion <op> <vmx> [soft|hard|nogui]` for this VM.
    static func parseOperation(_ args: String, vmx: String) -> (kind: PendingOperation.Kind, hard: Bool)? {
        guard let marker = args.range(of: " -T fusion ") else { return nil }
        let rest = args[marker.upperBound...]
        guard let space = rest.firstIndex(of: " "),
              let kind = PendingOperation.Kind(rawValue: String(rest[..<space])) else { return nil }
        var target = String(rest[rest.index(after: space)...])
        var hard = false
        for option in [" soft", " hard", " nogui", " gui"] where target.hasSuffix(option) {
            target.removeLast(option.count)
            hard = option == " hard"
        }
        return target == vmx ? (kind, hard) : nil
    }

    /// "0:c:29:6c:9b:3b" (arp) and "00:0C:29:6C:9B:3B" (.vmx) → "00:0c:29:6c:9b:3b".
    static func normalizeMAC(_ raw: String) -> String? {
        let octets = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard octets.count == 6, octets.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else {
            return nil
        }
        return octets.map { $0.count == 1 ? "0" + $0.lowercased() : $0.lowercased() }.joined(separator: ":")
    }

    /// ps etime: [[dd-]hh:]mm:ss.
    static func parseElapsed(_ etime: String) -> TimeInterval? {
        var days = 0.0
        var rest = Substring(etime)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + seconds
    }

    /// $1 is the vmrun path; the rest are user-added .vmx paths ("~/" allowed).
    static let script = #"""
    export LC_ALL=C
    VMRUN=$1; shift
    if [ ! -x "$VMRUN" ]; then
      printf 'ERR\tvmrun not found at %s. Is VMware Fusion installed on this Mac?\n' "$VMRUN"
      exit 0
    fi
    canon() {
      d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
      printf '%s/%s' "$d" "$(basename "$1")"
    }
    list=$("$VMRUN" -T fusion list 2>&1)
    rc=$?
    err=$(printf '%s\n' "$list" | grep '^Error:' | head -n 1)
    if [ $rc -ne 0 ] || [ -n "$err" ]; then
      printf 'ERR\tvmrun list failed: %s\n' "$(printf '%s' "${err:-$list}" | tr '\n\t' '  ')"
      exit 0
    fi
    running=$(printf '%s\n' "$list" | grep -v '^Total running VMs')
    printf '%s\n' "$running" | while IFS= read -r p; do
      [ -n "$p" ] && c=$(canon "$p") || continue
      printf 'RUN\t%s\n' "$c"
      # The guest's own address, as Tools publishes it (guestinfo.ip). This
      # works whenever Tools is alive. vmrun's getGuestIPAddress does not:
      # it insists on a separate "Tools running" handshake that Fusion 13
      # often never completes after a reboot, so it reports Tools as not
      # running while the guest is fine.
      ip=$("$VMRUN" -T fusion readVariable "$p" guestVar ip 2>&1 </dev/null | head -n 1)
      case $ip in Error:*) ip= ;; esac
      if [ -n "$ip" ]; then
        state=running
      else
        state=$("$VMRUN" -T fusion checkToolsState "$p" 2>&1 </dev/null | head -n 1)
        case $state in Error:*) state=unknown ;; esac
      fi
      printf 'GUEST\t%s\t%s\t%s\n' "$c" "$(printf '%s' "$ip" | tr '\t' ' ')" "$state"
    done
    inv="$HOME/Library/Application Support/VMware Fusion/vmInventory"
    # .vmx-style keys are case-insensitive, hence grep -i before sed.
    cfg() {
      grep -i "^$1 *=" "$2" | head -n 1 | sed -n 's/^[^=]*= *"\(.*\)"[[:space:]]*$/\1/p' | tr '\t' ' '
    }
    {
      printf '%s\n' "$running"
      for d in "$HOME/Virtual Machines.localized" "$HOME/Documents/Virtual Machines.localized" "$HOME/Virtual Machines" \
               "/Users/Shared/Virtual Machines.localized" "/Users/Shared/Virtual Machines"; do
        [ -d "$d" ] && find "$d" -maxdepth 4 -name '*.vmx' -type f 2>/dev/null
      done
      # Fusion's library. Older versions list VMs as vmlistN.config, newer
      # ones as indexN.id; both can appear, and either can be empty.
      [ -f "$inv" ] && grep -iE '^(vmlist[0-9]+\.config|index[0-9]+\.id) *=' "$inv" |
        sed -n 's/^[^=]*= *"\(.*\.vmx\)"[[:space:]]*$/\1/p'
      for p in "$@"; do printf '%s\n' "$p"; done
    } | awk 'NF && !seen[$0]++' | while IFS= read -r p; do
      case $p in "~/"*) p="$HOME/${p#??}" ;; esac
      [ -f "$p" ] || continue
      real=$(canon "$p") || continue
      dir=$(dirname "$real")
      susp=0
      for s in "$dir"/*.vmss; do [ -e "$s" ] && susp=1; break; done
      macs=$(grep -iE '^ethernet[0-9]+\.(generatedaddress|address) *=' "$real" |
        sed -n 's/^[^=]*= *"\(.*\)".*$/\1/p' | tr '\n' ',')
      printf 'VM\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$real" "$(cfg displayname "$real")" "$susp" \
        "$(cfg numvcpus "$real")" "$(cfg memsize "$real")" "$(cfg guestos "$real")" "$macs"
      df -Pk "$dir" 2>/dev/null | awk -v p="$real" 'NR == 2 {
        m = $6; for (i = 7; i <= NF; i++) m = m " " $i
        print "DF\t" p "\t" $2 "\t" $4 "\t" m }'
    done
    ps -Ao pid=,pcpu=,rss=,etime=,args= | grep '[v]mware-vmx' | while read -r pid cpu rss et args; do
      printf 'PS\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$cpu" "$rss" "$et" "$(printf '%s' "$args" | tr '\t' ' ')"
    done
    al="$HOME/Library/Application Support/VMDeck/autostart.list"
    [ -f "$al" ] && tail -n +3 "$al" | while IFS= read -r p; do
      [ -n "$p" ] && c=$(canon "$p") && printf 'AUTO\t%s\n' "$c"
    done
    rl="$HOME/Library/Application Support/VMDeck/restart.list"
    [ -f "$rl" ] && tail -n +3 "$rl" | while IFS="$(printf '\t')" read -r hour minute days enabled mode p; do
      [ -z "$p" ] && { p=$mode; mode=reboot; }
      [ -n "$p" ] && c=$(canon "$p") && printf 'SCHED\t%s\t%s\t%s\t%s\t%s\t%s\n' "$hour" "$minute" "$days" "$enabled" "$mode" "$c"
    done
    ps -Ao etime=,args= | grep -E '[v]mrun -T fusion (start|stop|suspend|reset) ' | while read -r et args; do
      printf 'OP\t%s\t%s\n' "$et" "$(printf '%s' "$args" | tr '\t' ' ')"
    done
    printf 'HOST\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(sysctl -n hw.ncpu)" "$(sysctl -n hw.memsize)" \
      "$(sysctl -n vm.loadavg | tr -d '{}' | awk '{ print $1 "," $2 "," $3 }')" \
      "$(sysctl -n kern.boottime | sed -n 's/^{ *sec = \([0-9]*\).*/\1/p')" \
      "$(sysctl -n hw.model)" "$(sw_vers -productVersion)"
    # "Used" as Activity Monitor counts it: active + wired + compressed.
    vm_stat | awk '
      /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
      /^Pages (active|wired down|occupied by compressor):/ { v = $NF; sub(/\./, "", v); used += v }
      END { if (ps) printf "MEM\t%.0f\n", used * ps }'
    for f in /var/db/vmware/vmnet-dhcpd-vmnet*.leases; do
      [ -r "$f" ] && awk '/^lease / { ip = $2 } /hardware ethernet/ { m = $3; sub(/;/, "", m); print "NET\t" ip "\t" m }' "$f"
    done
    arp -an 2>/dev/null | awk '$4 ~ /:/ { ip = $2; gsub(/[()]/, "", ip); print "NET\t" ip "\t" $4 }'
    exit 0
    """#
}
