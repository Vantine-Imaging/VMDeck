import Foundation
import Testing
@testable import VMDeck

private final class Token {}

@Suite(.serialized) struct PendingSettingsTests {
    let home: URL
    let vmrunPath: String
    let runner: LocalRunner
    var vmrun: VMRun { VMRun(runner: runner, vmrunPath: vmrunPath) }

    init() throws {
        let fm = FileManager.default
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        home = URL(fileURLWithPath: String(cString: tmp)).appending(path: "vmdeck-pend-\(UUID().uuidString)")
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

    @Test func parsesLinesAndStatus() {
        #expect(PendingSetting(line: "memsize = \"8192\"")?.value == "8192")
        #expect(PendingSetting(line: "cpuid.coresPerSocket=6")?.key == "cpuid.coresPerSocket")
        #expect(PendingSetting(line: "bad key = 1") == nil)
        #expect(PendingSetting(key: "a.b", value: "x\"y").line == "a.b = \"xy\"")
        let s = PendingSettingsManager.parseStatus("PEND\tnumvcpus = \"4\"\nCUR\tnumvcpus\t2\nCUR\tmemsize\t4096\nRO\n")
        #expect(s.pending.map(\.key) == ["numvcpus"])
        #expect(s.current["memsize"] == "4096" && !s.vmxWritable)
    }

    @Test func saveStatusApplyRoundTrip() async throws {
        let dir = home.appending(path: "Virtual Machines.localized/P.vmwarevm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vmx = dir.appending(path: "P.vmx").path
        try "displayName = \"P\"\nnumvcpus = \"2\"\nMEMSIZE = \"2048\"\n".write(toFile: vmx, atomically: true, encoding: .utf8)
        let manager = PendingSettingsManager(vmrun: vmrun)

        try await manager.save([PendingSetting(key: "numvcpus", value: "4"), PendingSetting(key: "memsize", value: "8192"),
                                PendingSetting(key: "mks.enable3d", value: "FALSE")], for: vmx)
        var s = try await manager.status(for: vmx)
        #expect(s.pending.map(\.line) == ["numvcpus = \"4\"", "memsize = \"8192\"", "mks.enable3d = \"FALSE\""])
        #expect(s.current["numvcpus"] == "2" && s.current["memsize"] == "2048" && s.current["mks.enable3d"] == nil)
        #expect(try await Discovery(vmrun: vmrun).discover().vms.first { $0.vmxPath == vmx }?.pendingSettings == 3)

        // Running: refused, nothing changes.
        try await vmrun.start(vmx)
        await #expect(throws: (any Error).self) { try await manager.applyNow(for: vmx) }
        try await vmrun.stop(vmx, hard: true)

        let applied = try await manager.applyNow(for: vmx)
        #expect(applied.count == 3)
        let text = try String(contentsOfFile: vmx, encoding: .utf8)
        #expect(text.contains("numvcpus = \"4\"") && !text.contains("numvcpus = \"2\""))
        #expect(text.contains("memsize = \"8192\"") && !text.contains("MEMSIZE = \"2048\""))   // case-insensitive replace
        #expect(text.hasSuffix("mks.enable3d = \"FALSE\"\n") && text.contains("displayName = \"P\""))
        #expect(FileManager.default.fileExists(atPath: vmx + ".vmdeck-backup"))
        s = try await manager.status(for: vmx)
        #expect(s.pending.isEmpty && s.current["numvcpus"] == "4")

        // Clearing removes the file.
        try await manager.save([PendingSetting(key: "x", value: "1")], for: vmx)
        try await manager.save([], for: vmx)
        #expect(!FileManager.default.fileExists(atPath: vmx + ".vmdeck-pending"))
    }
}
