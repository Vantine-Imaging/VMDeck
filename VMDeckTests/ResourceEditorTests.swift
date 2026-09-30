import Foundation
import Testing
@testable import VMDeck

private final class Token {}

/// Runs the real inspect/apply scripts against fixture VMs, with the fake
/// vmrun and vmware-vdiskmanager side by side as they are in Fusion.app.
@Suite(.serialized) struct ResourceEditorTests {
    let root: URL
    let editor: ResourceEditor
    let vmrun: VMRun

    init() throws {
        let fm = FileManager.default
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        root = URL(fileURLWithPath: String(cString: tmp)).appending(path: "vmdeck-res-\(UUID().uuidString)")
        let lib = root.appending(path: "Library")
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        let bundle = Bundle(for: Token.self)
        try fm.copyItem(at: try #require(bundle.url(forResource: "fake-vmrun", withExtension: nil)),
                        to: lib.appending(path: "vmrun"))
        try fm.copyItem(at: try #require(bundle.url(forResource: "fake-vdiskmanager", withExtension: nil)),
                        to: lib.appending(path: "vmware-vdiskmanager"))
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = root.path
        env["FAKE_VMRUN_STATE"] = root.appending(path: "running").path
        vmrun = VMRun(runner: LocalRunner(environment: env), vmrunPath: lib.appending(path: "vmrun").path)
        editor = ResourceEditor(vmrun: vmrun)
    }

    static func descriptor(_ type: String, extents: [Int], parent: Bool = false) -> String {
        var text = "# Disk DescriptorFile\nversion=1\nCID=fffffffe\nparentCID=ffffffff\ncreateType=\"\(type)\"\n"
        if parent { text += "parentFileNameHint=\"Base.vmdk\"\n" }
        text += "\n# Extent description\n"
        for (i, sectors) in extents.enumerated() {
            text += "RW \(sectors) SPARSE \"Disk-s00\(i + 1).vmdk\"\n"
        }
        return text + "\n# The Disk Data Base\nddb.adapterType = \"lsilogic\"\n"
    }

    /// A VM folder with the given .vmx body and files.
    @discardableResult
    func makeVM(_ name: String, vmx: String, files: [String: Data] = [:]) throws -> URL {
        let dir = root.appending(path: "\(name).vmwarevm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (file, data) in files {
            try data.write(to: dir.appending(path: file))
        }
        let url = dir.appending(path: "\(name).vmx")
        try vmx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func inspectsDisksOfEveryKind() async throws {
        // Monolithic sparse: binary header, descriptor embedded at sector 1.
        var mono = Data("KDMV".utf8) + Data(count: 508)
        mono += Data(Self.descriptor("monolithicSparse", extents: [41_943_040]).utf8)
        mono += Data(count: 2_000_000)
        let vmx = try makeVM("Kinds", vmx: """
        .encoding = "UTF-8"
        NumVCPUs = "4"
        MemSize = "8192"
        cpuid.coresPerSocket = "2"
        nvme0:0.present = "TRUE"
        nvme0:0.fileName = "Split.vmdk"
        sata0:0.present = "TRUE"
        sata0:0.fileName = "Mono.vmdk"
        sata0:1.present = "TRUE"
        sata0:1.deviceType = "cdrom-image"
        sata0:1.fileName = "/Users/x/Windows.iso"
        scsi0:1.present = "FALSE"
        scsi0:1.fileName = "Detached.vmdk"
        ide0:0.fileName = "Missing.vmdk"
        """, files: [
            "Split.vmdk": Data(Self.descriptor("twoGbMaxExtentSparse", extents: [8_323_072, 8_323_072]).utf8),
            "Mono.vmdk": mono,
            "Detached.vmdk": Data(Self.descriptor("monolithicSparse", extents: [2048]).utf8),
        ])

        let r = try await editor.inspect(vmx.path)
        #expect(r.vcpus == 4)
        #expect(r.memoryMB == 8192)
        #expect(r.coresPerSocket == 2)
        #expect(r.disks.map(\.device) == ["nvme0:0", "sata0:0", "ide0:0"])
        #expect(r.disks[0].capacityBytes == Int64(16_646_144) * 512)
        #expect(r.disks[0].createType == "twoGbMaxExtentSparse")
        #expect(r.disks[1].capacityBytes == Int64(20) * 1_073_741_824)
        #expect(r.disks[1].currentGB == 20)
        #expect(r.disks[2].missing)
        #expect(r.disks.allSatisfy { !$0.hasSnapshots })
        #expect(!r.locked)
    }

    @Test func snapshotsBlockGrowing() async throws {
        let vmx = try makeVM("Snap", vmx: """
        nvme0:0.fileName = "Disk.vmdk"
        nvme0:1.fileName = "Child.vmdk"
        """, files: [
            "Disk.vmdk": Data(Self.descriptor("monolithicSparse", extents: [2_097_152]).utf8),
            "Child.vmdk": Data(Self.descriptor("monolithicSparse", extents: [2_097_152], parent: true).utf8),
        ])
        var r = try await editor.inspect(vmx.path)
        #expect(r.disks.map(\.hasSnapshots) == [false, true])
        #expect(r.disks[1].cannotGrowReason != nil)

        try "snapshot.numSnapshots = \"1\"\n".write(
            to: vmx.deletingLastPathComponent().appending(path: "Snap.vmsd"), atomically: true, encoding: .utf8)
        r = try await editor.inspect(vmx.path)
        #expect(r.disks.allSatisfy { $0.hasSnapshots })
    }

    @Test func appliesCPUMemoryAndDiskAndKeepsABackup() async throws {
        let original = """
        .encoding = "UTF-8"
        displayName = "Edit Me"
        NumVCPUs = "2"
        MemSize = "4096"
        cpuid.coresPerSocket = "2"
        nvme0:0.fileName = "Disk.vmdk"
        """
        let vmx = try makeVM("Edit", vmx: original, files: [
            "Disk.vmdk": Data(Self.descriptor("monolithicSparse", extents: [20_971_520]).utf8),  // 10 GB
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: vmx.path)

        let current = try await editor.inspect(vmx.path)
        let change = ResourceChange.between(current, vcpus: 3, memoryMB: 6144,
                                            diskSizesMB: [current.disks[0].path: 20 * 1024])
        #expect(change.coresPerSocket == 3)  // 2 doesn't divide 3
        let done = try await editor.apply(change, to: vmx.path)
        #expect(done.count == 2)

        let text = try String(contentsOf: vmx, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.first == ".encoding = \"UTF-8\"")
        #expect(lines.contains("displayName = \"Edit Me\""))
        #expect(lines.filter { $0.lowercased().hasPrefix("numvcpus") } == ["numvcpus = \"3\""])
        #expect(lines.filter { $0.lowercased().hasPrefix("memsize") } == ["memsize = \"6144\""])
        #expect(lines.filter { $0.lowercased().hasPrefix("cpuid.corespersocket") } == ["cpuid.coresPerSocket = \"3\""])
        let backup = try String(contentsOf: URL(fileURLWithPath: vmx.path + ".vmdeck-backup"), encoding: .utf8)
        #expect(backup == original)
        let perms = try FileManager.default.attributesOfItem(atPath: vmx.path)[.posixPermissions] as? Int
        #expect(perms == 0o640)

        let after = try await editor.inspect(vmx.path)
        #expect(after.disks[0].currentGB == 20)
        #expect(after.vcpus == 3 && after.memoryMB == 6144)
    }

    @Test func refusesRunningAndSuspendedVMs() async throws {
        let vmx = try makeVM("Busy", vmx: "numvcpus = \"2\"\n")
        let change = ResourceChange(vcpus: 4)

        try await vmrun.start(vmx.path)
        await #expect(throws: VMRunError.vmrun("The VM is running. Shut it down first.")) {
            try await editor.apply(change, to: vmx.path)
        }
        try await vmrun.suspend(vmx.path)
        await #expect(throws: VMRunError.vmrun("The VM is suspended. Start it and shut it down first.")) {
            try await editor.apply(change, to: vmx.path)
        }
        // Nothing was written either time.
        #expect(try String(contentsOf: vmx, encoding: .utf8) == "numvcpus = \"2\"\n")
        #expect(!FileManager.default.fileExists(atPath: vmx.path + ".vmdeck-backup"))
    }

    @Test func diskFailureIsReported() async throws {
        let vmx = try makeVM("Fail", vmx: "nvme0:0.fileName = \"Child.vmdk\"\n", files: [
            "Child.vmdk": Data(Self.descriptor("monolithicSparse", extents: [2_097_152], parent: true).utf8),
        ])
        let path = vmx.deletingLastPathComponent().appending(path: "Child.vmdk").path
        await #expect(throws: VMRunError.self) {
            try await editor.apply(ResourceChange(diskSizesMB: [path: 4096]), to: vmx.path)
        }
    }

    @Test func untouchedValuesProduceNoChange() {
        // 60.5 GB disk: shown as 61 GB, and leaving it there must not grow it.
        let disk = VMDisk(device: "nvme0:0", path: "/d.vmdk", capacityBytes: 64_961_380_352,
                          createType: "monolithicSparse", hasSnapshots: false, missing: false)
        let current = VMResources(vcpus: 2, memoryMB: 4096, coresPerSocket: 1, disks: [disk],
                                  fusionAppRunning: false, locked: false)
        #expect(disk.currentGB == 61)
        #expect(ResourceChange.between(current, vcpus: 2, memoryMB: 4096, diskSizesMB: ["/d.vmdk": 61 * 1024]).isEmpty)
        let grow = ResourceChange.between(current, vcpus: 4, memoryMB: 4096, diskSizesMB: ["/d.vmdk": 62 * 1024])
        #expect(grow.vcpus == 4 && grow.coresPerSocket == nil)  // 1 divides everything
        #expect(grow.diskSizesMB == ["/d.vmdk": 62 * 1024])
    }
}
