import Foundation

/// Everything a host does on its own: which VMs start at login, and which
/// restart on a calendar. Two mechanisms underneath (one auto-start agent
/// that waits for volumes and starts VMs in order; one calendar agent per
/// scheduled VM), read in a single round trip.
struct AutomationStatus: Equatable, Sendable {
    var autoStart = AutoStartStatus()
    var restarts = ScheduledRestartStatus()

    /// What one VM is set to do.
    func summary(for vmxPath: String) -> String {
        var parts: [String] = []
        if autoStart.config.vmxPaths.contains(vmxPath) { parts.append("Starts at login") }
        if let s = restarts.schedules[vmxPath], s.enabled { parts.append("\(s.verb) \(s.sentenceLabel)") }
        return parts.isEmpty ? "Off" : parts.joined(separator: ", ")
    }
}

struct AutomationManager: Sendable {
    let vmrun: VMRun

    private static let separator = "@@VMDECK-RESTARTS@@"

    func status() async throws -> AutomationStatus {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.statusScript, "vmdeck-automation-status"],
                                                timeout: .seconds(20))
        try VMRun.check(result)
        return Self.parseStatus(result.stdout)
    }

    static func parseStatus(_ output: String) -> AutomationStatus {
        let halves = output.components(separatedBy: separator + "\n")
        var status = AutomationStatus()
        status.autoStart = AutoStartManager.parseStatus(halves[0])
        if halves.count > 1 { status.restarts = ScheduledRestartManager.parseStatus(halves[1]) }
        return status
    }

    /// Both status scripts, each in a subshell so its `exit` ends only itself.
    static let statusScript = "(\n\(AutoStartManager.statusScript)\n)\necho '\(separator)'\n(\n\(ScheduledRestartManager.statusScript)\n)\n"
}
