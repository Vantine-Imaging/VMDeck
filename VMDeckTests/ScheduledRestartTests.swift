import Foundation
import Testing
@testable import VMDeck

private final class Token {}

@Suite struct RestartScheduleModelTests {
    @Test func labels() {
        #expect(RestartSchedule(hour: 3, minute: 0).label == "Daily at 3:00")
        #expect(RestartSchedule(hour: 22, minute: 30, weekdays: Set(1...5)).label == "Weekdays at 22:30")
        #expect(RestartSchedule(hour: 4, minute: 5, weekdays: [0, 6]).label == "Weekends at 4:05")
        #expect(RestartSchedule(hour: 4, minute: 0, weekdays: [1, 3, 5]).label == "Mon, Wed, Fri at 4:00")
        #expect(RestartSchedule(hour: 4, minute: 0, weekdays: []).label == "Never")
        #expect(RestartSchedule(hour: 3, minute: 0).sentenceLabel == "daily at 3:00")
        #expect(RestartSchedule(hour: 4, minute: 30, weekdays: [0]).sentenceLabel == "Sun at 4:30")
    }

    @Test func nextRunHonorsDaysAndTime() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        // Wed 2026-09-30 10:00 local.
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10)))
        let sunday3 = RestartSchedule(hour: 3, minute: 0, weekdays: [0])
        let next = try #require(sunday3.nextRun(after: now, calendar: cal))
        let c = cal.dateComponents([.weekday, .day, .hour, .minute], from: next)
        #expect(c.weekday == 1 && c.day == 4 && c.hour == 3 && c.minute == 0)
        // Daily at 09:00 from 10:00 is tomorrow; at 11:00 is today.
        let tomorrow = try #require(RestartSchedule(hour: 9, minute: 0).nextRun(after: now, calendar: cal))
        #expect(cal.dateComponents([.day], from: tomorrow).day == 1)
        let today = try #require(RestartSchedule(hour: 11, minute: 0).nextRun(after: now, calendar: cal))
        #expect(cal.dateComponents([.day], from: today).day == 30)
        #expect(RestartSchedule(hour: 3, minute: 0, weekdays: [0], enabled: false).nextRun(after: now, calendar: cal) == nil)
    }

    @Test func idMatchesCksum() async throws {
        let path = "/Users/Shared/Virtual Machines/Win10 Sage Server.vmwarevm/Win10 Sage Server.vmx"
        let r = try await LocalRunner().run(["/bin/sh", "-c", "printf '%s' \"$1\" | cksum | cut -d' ' -f1", "x", path],
                                            timeout: .seconds(5))
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == ScheduledRestartManager.id(for: path))
    }

    @Test func parsesStatus() {
        let out = """
        WAIT\t300
        SCHED\t3\t0\t0\t1\t/a/A.vmx
        SCHED\t22\t30\t1,2,3,4,5\t0\t/b/B.vmx
        LOADED\t12345
        LOG\t2026-10-02 03:00:01 A: guest restarted
        """
        let s = ScheduledRestartManager.parseStatus(out)
        #expect(s.shutdownWaitSeconds == 300)
        #expect(s.schedules["/a/A.vmx"] == RestartSchedule(hour: 3, minute: 0, weekdays: [0], enabled: true))
        #expect(s.schedules["/b/B.vmx"] == RestartSchedule(hour: 22, minute: 30, weekdays: Set(1...5), enabled: false))
        #expect(s.loaded == ["12345"])
        #expect(s.recentLog.hasSuffix("A: guest restarted"))
    }
}

/// Runs the real install/status/restart scripts against a throwaway HOME and
/// the fake vmrun. launchctl is never touched.
@Suite(.serialized) struct ScheduledRestartScriptTests {
    let home: URL
    let vmrunPath: String
    let runner: LocalRunner
    var vmrun: VMRun { VMRun(runner: runner, vmrunPath: vmrunPath) }

    init() throws {
        let fm = FileManager.default
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        home = URL(fileURLWithPath: String(cString: tmp)).appending(path: "vmdeck-sched-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try #require(Bundle(for: Token.self).url(forResource: "fake-vmrun", withExtension: nil))
        let copy = home.appending(path: "fake-vmrun")
        try fm.copyItem(at: source, to: copy)
        vmrunPath = copy.path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["FAKE_VMRUN_STATE"] = home.appending(path: "running").path
        runner = LocalRunner(environment: env)
    }

    private func makeVM(_ name: String, extra: String = "") throws -> String {
        let dir = home.appending(path: "Virtual Machines.localized/\(name).vmwarevm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vmx = dir.appending(path: "\(name).vmx")
        try "displayName = \"\(name)\"\n\(extra)".write(to: vmx, atomically: true, encoding: .utf8)
        return vmx.path
    }

    private func install(_ schedules: [String: RestartSchedule], wait: Int) async throws -> String {
        var argv = ["/bin/sh", "-c", ScheduledRestartManager.installScript, "t", vmrunPath, String(wait), "0",
                    ScheduledRestartManager.runnerScript]
        for (path, s) in schedules.sorted(by: { $0.key < $1.key }) {
            argv += [String(s.hour), String(s.minute), s.weekdays.sorted().map(String.init).joined(separator: ","),
                     s.enabled ? "1" : "0", path]
        }
        let r = try await runner.run(argv, timeout: .seconds(20))
        try VMRun.check(r)
        return r.stdout
    }

    private func status() async throws -> ScheduledRestartStatus {
        ScheduledRestartManager.parseStatus(
            try await runner.run(["/bin/sh", "-c", ScheduledRestartManager.statusScript, "t"], timeout: .seconds(10)).stdout)
    }

    private func runRestart(_ vmx: String) async throws -> String {
        let script = home.appending(path: "Library/Application Support/VMDeck/restart.sh").path
        let r = try await runner.run(["/bin/sh", script, vmx], timeout: .seconds(90))
        return try String(contentsOf: home.appending(path: "Library/Logs/VMDeck/restart.log"), encoding: .utf8)
    }

    @Test func installWritesPlistsPerEnabledScheduleAndStatusReadsBack() async throws {
        let a = try makeVM("A"), b = try makeVM("B")
        let schedules = [
            a: RestartSchedule(hour: 3, minute: 15, weekdays: [0, 3]),
            b: RestartSchedule(hour: 22, minute: 0, weekdays: Set(1...5), enabled: false),
        ]
        let out = try await install(schedules, wait: 300)
        #expect(out.contains("OK\tscheduled A"))
        #expect(!out.contains("scheduled B"))

        let agents = home.appending(path: "Library/LaunchAgents")
        let plist = agents.appending(path: "\(ScheduledRestartManager.labelPrefix)\(ScheduledRestartManager.id(for: a)).plist")
        let dict = try #require(NSDictionary(contentsOf: plist))
        #expect((dict["ProgramArguments"] as? [String]) == ["/bin/sh", home.appending(path: "Library/Application Support/VMDeck/restart.sh").path, a])
        let intervals = try #require(dict["StartCalendarInterval"] as? [[String: Int]])
        #expect(intervals == [["Hour": 3, "Minute": 15, "Weekday": 0], ["Hour": 3, "Minute": 15, "Weekday": 3]])
        let files = try FileManager.default.contentsOfDirectory(atPath: agents.path).filter { $0.hasPrefix(ScheduledRestartManager.labelPrefix) }
        #expect(files.count == 1)

        let s = try await status()
        #expect(s.shutdownWaitSeconds == 300)
        #expect(s.schedules == schedules)

        // Discovery marks scheduled VMs.
        let vms = try await Discovery(vmrun: vmrun).discover().vms
        #expect(vms.first { $0.vmxPath == a }?.restartSchedule == schedules[a])
        #expect(vms.first { $0.vmxPath == b }?.restartSchedule == schedules[b])

        // Reinstall with A removed: its plist goes away.
        _ = try await install([b: schedules[b]!], wait: 300)
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }

    @Test func restartPrefersGuestRestartThenShutdownThenPowerOff() async throws {
        let polite = try makeVM("Polite")
        let noTools = try makeVM("NoTools", extra: "fake.resetFails = \"TRUE\"\n")
        let stuck = try makeVM("Stuck", extra: "fake.resetFails = \"TRUE\"\nfake.softStopHangs = \"TRUE\"\n")
        let off = try makeVM("Off")
        for vmx in [polite, noTools, stuck] { try await vmrun.start(vmx) }
        _ = try await install([polite: RestartSchedule()], wait: 6)

        var log = try await runRestart(polite)
        #expect(log.contains("Polite: guest restarted"))
        #expect(try await vmrun.list().contains(polite))

        log = try await runRestart(noTools)
        #expect(log.contains("NoTools: guest can't restart itself"))
        #expect(log.contains("NoTools: shut down cleanly"))
        #expect(log.contains("NoTools: started"))
        #expect(try await vmrun.list().contains(noTools))

        let start = ContinuousClock.now
        log = try await runRestart(stuck)
        let elapsed = ContinuousClock.now - start
        #expect(log.contains("Stuck: still running after 6s, powering off"))
        #expect(log.contains("Stuck: started"))
        #expect(elapsed > .seconds(6) && elapsed < .seconds(40))
        #expect(try await vmrun.list().contains(stuck))

        log = try await runRestart(off)
        #expect(log.contains("Off: not running, skipped"))
        #expect(!(try await vmrun.list()).contains(off))
    }
}

@Suite struct AutomationStatusTests {
    @Test func combinesBothStatusesFromOneScript() async throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "vmdeck-auto-status-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "Library/Application Support/VMDeck"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "Library/LaunchAgents"), withIntermediateDirectories: true)
        let support = home.appending(path: "Library/Application Support/VMDeck")
        try "600 15\n/x/vmrun\n/a/A.vmx\n".write(to: support.appending(path: "autostart.list"), atomically: true, encoding: .utf8)
        try "/x/vmrun\n300\n3\t0\t0,6\t1\t/a/A.vmx\n".write(to: support.appending(path: "restart.list"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        let r = try await LocalRunner(environment: env).run(["/bin/sh", "-c", AutomationManager.statusScript, "t"], timeout: .seconds(10))
        let s = AutomationManager.parseStatus(r.stdout)
        #expect(!s.autoStart.installed)
        #expect(s.autoStart.config == AutoStartConfig(vmxPaths: ["/a/A.vmx"], waitSeconds: 600, staggerSeconds: 15))
        #expect(s.restarts.shutdownWaitSeconds == 300)
        #expect(s.restarts.schedules["/a/A.vmx"] == RestartSchedule(hour: 3, minute: 0, weekdays: [0, 6]))
        #expect(s.summary(for: "/a/A.vmx") == "Starts at login, Restarts weekends at 3:00")
        #expect(s.summary(for: "/b/B.vmx") == "Off")
    }
}
