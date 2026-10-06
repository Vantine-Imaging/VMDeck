import Foundation
import Testing
@testable import VMDeck

@Suite struct VMHistoryTests {
    static let sample = """
    LOG\t2026-10-02T01:05:27.000Z Log for VMware Fusion pid=1 version=13.6.4
    LOG\t2026-10-02T01:05:28.000Z numa: Resuming from checkpoint using VPD = 6
    LOG\t2026-10-03T02:00:01.084Z Vix: [vmxCommands.c:595]: VMAutomation_Reset
    LOG\t2026-10-03T02:00:01.084Z Vix: [vmxCommands.c:671]: VMAutomation_ResetImpl: SoftReboot succeeded.
    LOG\t2026-10-03T02:01:33.103Z Chipset: The guest has requested that the virtual machine be hard reset.
    LOG\t2026-10-03T02:01:45.406Z DarwinPanic: panic(cpu 0 caller 0xffffff801a1fe255): Kernel trap at 0xffffff801a635404, type 14=page fault, registers:
    LOG\t2026-10-03T02:01:48.407Z Chipset: The guest has requested that the virtual machine be hard reset.
    LOG\t2026-10-03T02:02:52.007Z Tools: State change '3' progress: last event 0, event 1, success 1.
    LOG\t2026-10-06T01:28:05.000Z Transitioned vmx/execState/val to suspended
    LOG\t2026-10-06T13:45:38.000Z Log for VMware Fusion pid=2 version=13.6.4
    LOG\t2026-10-06T13:46:00.000Z Chipset: The guest has requested that the virtual machine be powered off.
    LOG\t2026-10-06T13:46:05.000Z Transitioned vmx/execState/val to poweredOff
    SCHED\t2026-10-02 22:00:00 MailServer: scheduled restart
    SCHED\t2026-10-02 22:02:52 MailServer: guest restarted
    """

    @Test func classifiesFusionLogLines() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let h = VMHistoryManager.parse(Self.sample, calendar: cal)
        let kinds = h.events.map(\.kind)
        #expect(kinds == [.resume, .scheduled, .resetRequest, .guestReboot, .panic, .guestReboot, .scheduled, .toolsUp,
                          .suspend, .powerOn, .guestShutdown])
        #expect(h.count(.panic) == 1)
        #expect(h.boots == 2)
        let panic = try #require(h.events.first { $0.kind == .panic })
        #expect(panic.detail.hasPrefix("panic(cpu 0 caller"))
        // Scheduled lines are host-local (New York): 22:00 EDT == 02:00Z next day.
        let sched = try #require(h.events.first { $0.kind == .scheduled })
        #expect(sched.date == ISO8601DateFormatter().date(from: "2026-10-03T02:00:00Z"))
        #expect(sched.detail == "scheduled restart")
        #expect(h.since == ISO8601DateFormatter().date(from: "2026-10-02T01:05:27Z"))
        // The powered-off transition right after a guest shutdown is folded into it.
        #expect(h.count(.powerOff) == 0)
    }

    @Test func scriptReadsRotatedLogsAndRestartLog() async throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "vmdeck-hist-\(UUID().uuidString)")
        let dir = home.appending(path: "Virtual Machines.localized/Mail.vmwarevm")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "Library/Logs/VMDeck"), withIntermediateDirectories: true)
        let vmx = dir.appending(path: "Mail.vmx")
        try "displayName = \"Mail\"\n".write(to: vmx, atomically: true, encoding: .utf8)
        try """
        2026-09-01T10:00:00.000Z In(05) host-1 Log for VMware Fusion pid=1 version=13.6.4
        2026-09-01T10:00:30.000Z In(05) vmx Tools: State change '3' progress: last event 0, event 1, success 1.
        2026-09-02T10:00:00.000Z In(05) vmx Transitioned vmx/execState/val to suspended
        """.write(to: dir.appending(path: "vmware-0.log"), atomically: true, encoding: .utf8)
        try """
        2026-09-03T10:00:00.000Z In(05) host-2 Log for VMware Fusion pid=2 version=13.6.4
        2026-09-03T10:00:01.000Z In(05) vmx numa: Resuming from checkpoint using VPD = 6
        2026-09-03T12:00:00.000Z Wa(03) vcpu-1 DarwinPanic: panic(cpu 1 caller 0xff): "a freed zone element has been modified"
        2026-09-03T12:00:03.000Z In(05) vcpu-0 Chipset: The guest has requested that the virtual machine be hard reset.
        2026-09-03T12:00:03.100Z In(05) vmx Vix: [mainDispatch.c:1059]: VMAutomation: Connection Error (4) on connection 5.
        """.write(to: dir.appending(path: "vmware.log"), atomically: true, encoding: .utf8)
        try "2026-09-03 08:00:00 Mail: scheduled restart\n2026-09-03 08:00:00 Other: scheduled restart\n"
            .write(to: home.appending(path: "Library/Logs/VMDeck/restart.log"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        let r = try await LocalRunner(environment: env).run(["/bin/sh", "-c", VMHistoryManager.script, "t", vmx.path], timeout: .seconds(10))
        try VMRun.check(r)
        let h = VMHistoryManager.parse(r.stdout)
        #expect(h.events.map(\.kind).filter { $0 != .scheduled } == [.powerOn, .toolsUp, .suspend, .resume, .panic, .guestReboot])
        #expect(h.count(.scheduled) == 1)
        #expect(h.events.first { $0.kind == .panic }?.detail.contains("freed zone element") == true)
        #expect(!r.stdout.contains("Connection Error"))
    }
}
