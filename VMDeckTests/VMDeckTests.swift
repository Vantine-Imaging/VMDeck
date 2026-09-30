import Foundation
import Testing
@testable import VMDeck

@Suite struct ShellQuoteTests {
    @Test func plainWordsPassThrough() {
        #expect(shellQuote("/usr/bin/vmrun") == "/usr/bin/vmrun")
        #expect(shellQuote("-T") == "-T")
    }

    @Test func spacesAndQuotesAreQuoted() {
        #expect(shellQuote("/Users/a/Virtual Machines.localized/x.vmx") == "'/Users/a/Virtual Machines.localized/x.vmx'")
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        #expect(shellQuote("") == "''")
        #expect(shellQuote("$HOME") == "'$HOME'")
    }

    @Test func quotedArgvSurvivesAShell() async throws {
        let argv = ["/bin/echo", "a b", "it's", "$HOME", "semi;colon", "tab\there"]
        let command = argv.map(shellQuote).joined(separator: " ")
        let result = try await LocalRunner().run(["/bin/sh", "-c", command], timeout: .seconds(5))
        #expect(result.stdout == "a b it's $HOME semi;colon tab\there\n")
    }

    @Test func sshArgumentsEndWithOneRemoteCommand() {
        let args = SSHRunner.sshArguments(
            for: SSHTarget(user: "alec", hostname: "mini.local", port: 2222),
            remoteArgv: ["/bin/sh", "-c", "echo hi"])
        #expect(args.suffix(3) == ["alec@mini.local", "--", "/bin/sh -c 'echo hi'"])
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("2222"))
    }
}

@Suite struct VMRunParsingTests {
    @Test func parsesList() {
        let output = "Total running VMs: 2\n/a/One.vmx\n/b/Two Words.vmx\n"
        #expect(VMRun.parseList(output) == ["/a/One.vmx", "/b/Two Words.vmx"])
        #expect(VMRun.parseList("Total running VMs: 0\n").isEmpty)
    }

    @Test func vmrunErrorOnStdoutWins() {
        let result = CommandResult(status: 255, stdout: "Error: The virtual machine is not powered on: /x.vmx\n", stderr: "")
        #expect(throws: VMRunError.vmrun("The virtual machine is not powered on: /x.vmx")) {
            try VMRun.check(result)
        }
    }

    @Test func sshFailureUsesStderr() {
        let result = CommandResult(status: 255, stdout: "", stderr: "alec@mini: Permission denied (publickey).\n")
        #expect(throws: VMRunError.failed("alec@mini: Permission denied (publickey).")) {
            try VMRun.check(result)
        }
    }

    @Test func parsesDiscoveryAndDedupes() {
        let output = """
        RUN\t/vms/B.vmwarevm/B.vmx
        VM\t/vms/B.vmwarevm/B.vmx\tBravo\t0
        VM\t/vms/A.vmwarevm/A.vmx\t\t1
        VM\t/vms/B.vmwarevm/B.vmx\tBravo\t0
        VM\t/vms/C.vmwarevm/C.vmx\tcharlie\t0
        """
        let parsed = Discovery.parse(output)
        #expect(parsed.error == nil)
        #expect(parsed.vms == [
            DiscoveredVM(vmxPath: "/vms/A.vmwarevm/A.vmx", displayName: "A", powerState: .suspended),
            DiscoveredVM(vmxPath: "/vms/B.vmwarevm/B.vmx", displayName: "Bravo", powerState: .running),
            DiscoveredVM(vmxPath: "/vms/C.vmwarevm/C.vmx", displayName: "charlie", powerState: .stopped),
        ])
    }

    @Test func parsesDiscoveryError() {
        #expect(Discovery.parse("ERR\tvmrun not found at /nope\n").error == "vmrun not found at /nope")
    }
}

private final class BundleToken {}

/// Runs the real discovery script and the fake vmrun against a throwaway HOME.
@Suite(.serialized) struct FakeFusionTests {
    let home: URL
    let vmrunPath: String
    let runner: LocalRunner

    init() throws {
        let fm = FileManager.default
        // The script canonicalizes with `pwd -P` (/var → /private/var). Match
        // it with realpath(3); URL.resolvingSymlinksInPath goes the other way.
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        home = URL(fileURLWithPath: String(cString: tmp))
            .appending(path: "vmdeck-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        // From the test bundle, never the repo: see project.yml.
        let source = try #require(Bundle(for: BundleToken.self).url(forResource: "fake-vmrun", withExtension: nil))
        let copy = home.appending(path: "fake-vmrun")
        try fm.copyItem(at: source, to: copy)
        vmrunPath = copy.path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["FAKE_VMRUN_STATE"] = home.appending(path: "running").path
        runner = LocalRunner(environment: env)
    }

    @discardableResult
    func makeVM(_ relativeDir: String, name: String, displayName: String?, extra: String = "") throws -> String {
        let dir = home.appending(path: relativeDir).appending(path: "\(name).vmwarevm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var vmx = ".encoding = \"UTF-8\"\nconfig.version = \"8\"\n"
        if let displayName { vmx += "displayName = \"\(displayName)\"\n" }
        vmx += extra
        let url = dir.appending(path: "\(name).vmx")
        try vmx.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    var vmrun: VMRun { VMRun(runner: runner, vmrunPath: vmrunPath) }

    @Test func discoversScannedInventoryAndExtraVMsOnce() async throws {
        let a = try makeVM("Virtual Machines.localized", name: "Alpha", displayName: "Alpha Linux")
        let b = try makeVM("Documents/Virtual Machines.localized", name: "Beta", displayName: nil)
        let c = try makeVM("Elsewhere/Deep Folder", name: "Gamma", displayName: "Gamma's Box")
        let d = try makeVM("Inventory Only", name: "Delta", displayName: "Delta")

        // Fusion's inventory lists Alpha again (dedupe) and Delta (new).
        let invDir = home.appending(path: "Library/Application Support/VMware Fusion")
        try FileManager.default.createDirectory(at: invDir, withIntermediateDirectories: true)
        try """
        .encoding = "UTF-8"
        vmlist1.config = "\(a)"
        vmlist1.DisplayName = "Alpha Linux"
        vmlist2.config = "\(d)"
        vmlist3.config = "folder1"
        """.write(to: invDir.appending(path: "vmInventory"), atomically: true, encoding: .utf8)

        // Gamma is added by the user through a symlinked folder, plus a ~/ path.
        let link = home.appending(path: "Shortcut")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: home.appending(path: "Elsewhere"))
        let extras = [link.appending(path: "Deep Folder/Gamma.vmwarevm/Gamma.vmx").path,
                      "~/Elsewhere/Deep Folder/Gamma.vmwarevm/Gamma.vmx",
                      "/does/not/exist.vmx"]

        let vms = try await Discovery(vmrun: vmrun).discover(extraPaths: extras).vms
        #expect(vms.map(\.vmxPath) == [a, b, d, c])
        #expect(vms.map(\.displayName) == ["Alpha Linux", "Beta", "Delta", "Gamma's Box"])
        #expect(vms.allSatisfy { $0.powerState == .stopped })
    }

    @Test func readsNewerInventoryFormatAndLowercaseKeys() async throws {
        // Newer Fusion: the library is indexN.id, vmlist1.config is empty,
        // and .vmx files may spell the key "displayname".
        let dir = home.appending(path: "Volumes/HP2/virtual_machines/Win10 Base.vmwarevm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vmx = dir.appending(path: "Win10 Base.vmx")
        try "displayname = \"Win10 Base\"\n".write(to: vmx, atomically: true, encoding: .utf8)
        let invDir = home.appending(path: "Library/Application Support/VMware Fusion")
        try FileManager.default.createDirectory(at: invDir, withIntermediateDirectories: true)
        try """
        .encoding = "UTF-8"
        vmlist1.config = ""
        index0.field0.name = "guest"
        index0.hostID = "localhost"
        index0.id = "\(vmx.path)"
        index1.id = "/Volumes/Unmounted/Gone.vmwarevm/Gone.vmx"
        index.count = "2"
        """.write(to: invDir.appending(path: "vmInventory"), atomically: true, encoding: .utf8)

        let vms = try await Discovery(vmrun: vmrun).discover().vms
        #expect(vms.map(\.vmxPath) == [vmx.path])
        #expect(vms.first?.displayName == "Win10 Base")
        #expect(vms.first?.powerState == .stopped)
    }

    @Test @MainActor func vmFoundOnlyWhileRunningStaysListedAfterStop() async throws {
        // Not in a scanned folder, not in the inventory: only vmrun list knows it.
        let vmx = try makeVM("Some Volume/odd place", name: "Hidden", displayName: "Hidden")
        try await vmrun.start(vmx)
        let store = VMStore(host: Host(name: "t", kind: .local, vmrunPath: vmrunPath), vmrun: vmrun)
        await store.refresh()
        let vm = try #require(store.vms.first { $0.id == vmx })

        await store.perform(.stop, on: vm)
        #expect(store.vms.first { $0.id == vmx }?.powerState == .stopped)
    }

    @Test func lifecycleRoundTrip() async throws {
        let vmx = try makeVM("Virtual Machines.localized", name: "Life", displayName: "Life")
        func found() async throws -> DiscoveredVM? {
            try await Discovery(vmrun: vmrun).discover().vms.first { $0.vmxPath == vmx }
        }
        func state() async throws -> PowerState? { try await found()?.powerState }

        #expect(try await state() == .stopped)
        #expect(try await found()?.guestIP == nil)

        try await vmrun.start(vmx)
        #expect(try await state() == .running)
        #expect(try await vmrun.list() == [vmx])
        #expect(try await found()?.guestIP?.hasPrefix("192.168.64.") == true)
        #expect(try await found()?.tools == .running)

        try await vmrun.suspend(vmx)
        #expect(try await state() == .suspended)

        try await vmrun.start(vmx)
        #expect(try await state() == .running)

        try await vmrun.reset(vmx)
        try await vmrun.stop(vmx, hard: false)
        #expect(try await state() == .stopped)

        await #expect(throws: VMRunError.vmrun("The virtual machine is not powered on: \(vmx)")) {
            try await vmrun.stop(vmx, hard: false)
        }
    }

    @Test @MainActor func storeOffersForceStopAfterSoftStopFails() async throws {
        let vmx = try makeVM("Virtual Machines.localized", name: "NoTools", displayName: "No Tools",
                             extra: "fake.softStopFails = \"TRUE\"\n")
        try await vmrun.start(vmx)

        let store = VMStore(host: Host(name: "t", kind: .local, vmrunPath: vmrunPath), vmrun: vmrun)
        await store.refresh()
        let vm = try #require(store.vms.first { $0.id == vmx })
        #expect(store.actions(for: vm) == [.stop, .suspend, .reset])
        #expect(vm.ipAddress != nil)

        await store.perform(.stop, on: vm)
        #expect(store.rowErrors[vmx]?.contains("VMware Tools") == true)
        #expect(store.actions(for: vm) == [.stop, .forceStop, .suspend, .reset])

        await store.perform(.forceStop, on: vm)
        #expect(store.vms.first { $0.id == vmx }?.powerState == .stopped)
        #expect(store.softStopFailed.isEmpty)
    }

    @Test func toolsNotRunningIsReported() async throws {
        let vmx = try makeVM("Virtual Machines.localized", name: "Booting", displayName: "Booting",
                             extra: "fake.toolsRunning = \"FALSE\"\n")
        try await vmrun.start(vmx)
        let vm = try #require(try await Discovery(vmrun: vmrun).discover().vms.first { $0.vmxPath == vmx })
        #expect(vm.guestIP == nil)
        #expect(vm.tools == .installed)
    }

    @Test @MainActor func forceStopCutsShortAHungShutdownWithoutAnError() async throws {
        let vmx = try makeVM("Virtual Machines.localized", name: "Slow", displayName: "Slow",
                             extra: "fake.softStopHangs = \"TRUE\"\n")
        try await vmrun.start(vmx)
        let store = VMStore(host: Host(name: "t", kind: .local, vmrunPath: vmrunPath), vmrun: vmrun)
        await store.refresh()
        let vm = try #require(store.vms.first { $0.id == vmx })

        let shutdown = Task { await store.perform(.stop, on: vm) }
        while store.activity(for: vm) == nil { await Task.yield() }
        let activity = try #require(store.activity(for: vm))
        #expect(activity.label == "Shutting down")
        #expect(activity.canForceStop)
        // A second clean shutdown is refused while one is pending.
        await store.perform(.suspend, on: vm)

        await store.perform(.forceStop, on: vm)
        await shutdown.value
        #expect(store.vms.first { $0.id == vmx }?.powerState == .stopped)
        #expect(store.rowErrors[vmx] == nil)
        #expect(store.activity(for: vm) == nil)
    }

    @Test func unknownGuestIPIsNotAnAddress() async throws {
        let vmx = try makeVM("Virtual Machines.localized", name: "Unk", displayName: "Unk",
                             extra: "fake.guestIP = \"unknown\"\n")
        try await vmrun.start(vmx)
        let vm = try #require(try await Discovery(vmrun: vmrun).discover().vms.first { $0.vmxPath == vmx })
        #expect(vm.guestIP == nil)
        #expect(VMRun.isIPAddress("192.168.2.143"))
        #expect(VMRun.isIPAddress("fe80::20c:29ff:fe6c:9b3b"))
        #expect(!VMRun.isIPAddress("unknown"))
    }

    /// A vmrun command already running on the host (say, a clean shutdown
    /// sent before VMDeck was relaunched) shows as activity in a fresh store.
    @Test @MainActor func hostSidePendingStopShowsInAFreshStore() async throws {
        let vmx = try makeVM("Virtual Machines.localized", name: "Pend", displayName: "Pend",
                             extra: "fake.softStopHangs = \"TRUE\"\n")
        try await vmrun.start(vmx)
        // Someone else's clean shutdown, left running.
        let orphan = Task { try? await vmrun.stop(vmx, hard: false) }
        defer { orphan.cancel() }

        let store = VMStore(host: Host(name: "t", kind: .local, vmrunPath: vmrunPath), vmrun: vmrun)
        var activity: VMStore.Activity?
        for _ in 0..<50 {
            await store.refresh()
            if let vm = store.vms.first(where: { $0.id == vmx }), let a = store.activity(for: vm) {
                activity = a
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(activity?.label == "Shutting down")
        #expect(activity?.canForceStop == true)

        let vm = try #require(store.vms.first { $0.id == vmx })
        await store.perform(.forceStop, on: vm)
        #expect(store.vms.first { $0.id == vmx }?.powerState == .stopped)
        _ = await orphan.value
    }

    @Test func missingVMRunIsReported() async throws {
        let broken = VMRun(runner: runner, vmrunPath: "/nope/vmrun")
        await #expect(throws: VMRunError.vmrun("vmrun not found at /nope/vmrun. Is VMware Fusion installed on this Mac?")) {
            try await Discovery(vmrun: broken).discover()
        }
    }

    @Test func timeoutKillsTheCommand() async throws {
        let start = ContinuousClock.now
        await #expect(throws: CommandError.self) {
            try await LocalRunner().run(["/bin/sleep", "10"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
