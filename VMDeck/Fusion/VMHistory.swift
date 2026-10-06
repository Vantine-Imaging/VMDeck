import Foundation

/// One thing that happened to a VM, as recorded in Fusion's per-VM logs
/// (`vmware.log` and its rotated predecessors) or in VMDeck's restart log.
struct VMEvent: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case powerOn, resume, suspend, powerOff, guestShutdown, guestReboot, resetRequest, panic, toolsUp, scheduled

        var label: String {
            switch self {
            case .powerOn: "Powered on"
            case .resume: "Resumed"
            case .suspend: "Suspended"
            case .powerOff: "Powered off"
            case .guestShutdown: "Guest shut down"
            case .guestReboot: "Guest rebooted"
            case .resetRequest: "Restart requested"
            case .panic: "Kernel panic"
            case .toolsUp: "Guest up"
            case .scheduled: "Scheduled restart"
            }
        }

        var systemImage: String {
            switch self {
            case .powerOn: "power"
            case .resume: "play.circle"
            case .suspend: "pause.circle"
            case .powerOff: "stop.circle"
            case .guestShutdown: "stop.circle"
            case .guestReboot: "arrow.clockwise.circle"
            case .resetRequest: "arrow.clockwise"
            case .panic: "exclamationmark.triangle.fill"
            case .toolsUp: "checkmark.circle"
            case .scheduled: "clock.arrow.2.circlepath"
            }
        }

        var isProblem: Bool { self == .panic }
    }

    let date: Date
    let kind: Kind
    /// Extra text: the panic string, what the restart script did, etc.
    var detail: String = ""

    var id: String { "\(date.timeIntervalSince1970)-\(kind.rawValue)-\(detail.hashValue)" }
}

struct VMHistory: Equatable, Sendable {
    var events: [VMEvent] = []
    /// Fusion keeps the current log and up to three before it, so history
    /// starts at the oldest session still on disk.
    var since: Date?

    func count(_ kind: VMEvent.Kind) -> Int { events.filter { $0.kind == kind }.count }
    /// Times the VM process came up: cold power-ons plus resumes from suspend.
    var boots: Int { count(.powerOn) + count(.resume) }
}

/// Reads a VM's history off the host in one round trip.
struct VMHistoryManager: Sendable {
    let vmrun: VMRun

    func history(for vmxPath: String) async throws -> VMHistory {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.script, "vmdeck-history", vmxPath],
                                                timeout: .seconds(60))
        try VMRun.check(result)
        return Self.parse(result.stdout)
    }

    /// Lines are emitted oldest first: `LOG\t<vmware.log line>` for the
    /// matched Fusion lines, `SCHED\t<restart.log line>` for VMDeck's own.
    static func parse(_ output: String, calendar: Calendar = .current) -> VMHistory {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let local = DateFormatter()
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var events: [VMEvent] = []
        var since: Date?
        var sessionStart: Int?
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let line = String(parts[1])
            switch parts[0] {
            case "LOG":
                guard let space = line.firstIndex(of: " "),
                      let date = iso.date(from: String(line[..<space])) ?? isoPlain.date(from: String(line[..<space]))
                else { continue }
                if since == nil || date < since! { since = date }
                let text = line[line.index(after: space)...]
                if text.contains("Log for VMware") {
                    sessionStart = events.count
                    events.append(VMEvent(date: date, kind: .powerOn))
                } else if text.contains("Resuming from checkpoint") {
                    if let i = sessionStart, i < events.count, events[i].kind == .powerOn {
                        events[i] = VMEvent(date: events[i].date, kind: .resume)
                    } else {
                        events.append(VMEvent(date: date, kind: .resume))
                    }
                } else if text.contains("execState/val to suspended") || text.contains("VMAutomation_Suspend") {
                    if let last = events.last, last.kind == .suspend, date.timeIntervalSince(last.date) < 600 { continue }
                    events.append(VMEvent(date: date, kind: .suspend))
                } else if text.contains("be powered off") {
                    events.append(VMEvent(date: date, kind: .guestShutdown))
                } else if text.contains("execState/val to poweredOff") {
                    // A guest shutdown already produced an event moments earlier.
                    if let last = events.last, last.kind == .guestShutdown, date.timeIntervalSince(last.date) < 600 { continue }
                    events.append(VMEvent(date: date, kind: .powerOff))
                } else if text.contains("be hard reset") {
                    events.append(VMEvent(date: date, kind: .guestReboot))
                } else if text.contains("VMAutomation_Reset") && !text.contains("ResetImpl") {
                    events.append(VMEvent(date: date, kind: .resetRequest, detail: "Through VMware Tools"))
                } else if let r = text.range(of: "DarwinPanic: ") {
                    var detail = String(text[r.upperBound...])
                    if detail.count > 160 { detail = String(detail.prefix(160)) + "…" }
                    events.append(VMEvent(date: date, kind: .panic, detail: detail))
                } else if text.contains("Tools: State change '3' progress: last event 0") {
                    events.append(VMEvent(date: date, kind: .toolsUp, detail: "VMware Tools running"))
                }
            case "SCHED":
                // "2026-10-02 22:00:00 Name: what happened", in the host's local time.
                guard line.count > 20, let date = local.date(from: String(line.prefix(19))) else { continue }
                let rest = line.dropFirst(20)
                let detail = rest.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? String(rest)
                events.append(VMEvent(date: date, kind: .scheduled, detail: detail))
            default:
                continue
            }
        }
        events.sort { $0.date < $1.date }
        return VMHistory(events: events, since: since)
    }

    /// $1 is the .vmx path. Walks the rotated logs oldest first, then the
    /// current one, then VMDeck's restart log for this VM's name.
    static let script = #"""
    vmx=$1
    dir=$(dirname "$vmx"); name=$(basename "$vmx" .vmx)
    for f in "$dir"/vmware-2.log "$dir"/vmware-1.log "$dir"/vmware-0.log "$dir"/vmware.log; do
      [ -f "$f" ] || continue
      LC_ALL=C grep -aE "Log for VMware|Resuming from checkpoint|execState/val to (suspended|poweredOff)|VMAutomation_Suspend|guest has requested that the virtual machine be (hard reset|powered off)|VMAutomation_Reset$|VMAutomation_Reset |DarwinPanic: panic|Tools: State change '3' progress: last event 0, event 1" "$f" |
        sed -E "s/^([^ ]+) (In|Wa|No|Er)\([0-9]+\) [^ ]+ /\1 /" | cut -c1-400 | sed 's/^/LOG\t/'
    done
    rl="$HOME/Library/Logs/VMDeck/restart.log"
    [ -f "$rl" ] && grep -aF " $name: " "$rl" | tail -n 200 | sed 's/^/SCHED\t/'
    exit 0
    """#
}
