import Foundation
import Testing
@testable import VMDeck

private final class Token {}

@Suite struct RemoteDesktopTests {
    @Test func picksProtocolByGuestOS() {
        #expect(RemoteDesktop.kind(forGuestOS: "windows9-64") == .rdp)
        #expect(RemoteDesktop.kind(forGuestOS: "windows11-64") == .rdp)
        #expect(RemoteDesktop.kind(forGuestOS: "darwin16-64") == .vnc)
        #expect(RemoteDesktop.kind(forGuestOS: "ubuntu-64") == .vnc)
        #expect(RemoteDesktop.kind(forGuestOS: nil) == .vnc)
    }

    @Test func buildsConnectionDetails() {
        #expect(RemoteDesktop.vncURL(ip: "192.168.2.105")?.absoluteString == "vnc://192.168.2.105")
        let rdp = RemoteDesktop.rdpFileContents(ip: "192.168.2.143", name: "George")
        #expect(rdp.hasPrefix("full address:s:192.168.2.143:3389\n"))
        #expect(rdp.contains("prompt for credentials:i:1"))
        #expect(RemoteDesktop.rdpFileContents(ip: "fe80::1", name: "x").hasPrefix("full address:s:[fe80::1]:3389\n"))
    }

    @Test @MainActor func onlyRunningVMsWithAnAddressGetATarget() {
        var vm = VirtualMachine(vmxPath: "/x.vmx", displayName: "x", powerState: .running)
        #expect(RemoteDesktop.target(for: vm) == nil)
        vm.ipAddress = "10.0.0.5"
        vm.config.guestOS = "windows9-64"
        #expect(RemoteDesktop.target(for: vm)?.kind == .rdp)
        vm.powerState = .stopped
        #expect(RemoteDesktop.target(for: vm) == nil)
    }
}

@Suite struct AutoStartParsingTests {
    @Test func parsesStatus() {
        let out = """
        INSTALLED\t1
        LOADED\t0
        WAIT\t900
        STAGGER\t20
        VM\t/Volumes/HP1/Virtual Machines/Mail.vmwarevm/Mail.vmx
        VM\t/Users/Shared/Virtual Machines/A.vmwarevm/A.vmx
        CONSOLE\tAdmin
        AUTOLOGIN\t
        LOG\t=== 2026-09-30 10:00:00 auto-start begins
        LOG\tMail: started
        """
        let s = AutoStartManager.parseStatus(out)
        #expect(s.installed && !s.loaded)
        #expect(s.config == AutoStartConfig(vmxPaths: ["/Volumes/HP1/Virtual Machines/Mail.vmwarevm/Mail.vmx",
                                                       "/Users/Shared/Virtual Machines/A.vmwarevm/A.vmx"],
                                            waitSeconds: 900, staggerSeconds: 20))
        #expect(s.consoleUser == "Admin")
        #expect(s.autoLoginUser == nil)
        #expect(s.recentLog.hasSuffix("Mail: started"))
    }
}

/// Runs the real install/status/runner scripts against a throwaway HOME with
/// the fake vmrun. launchctl is never touched (the install script's 4th
/// argument is 0 here).
@Suite(.serialized) struct AutoStartScriptTests {
    let home: URL
    let vmrunPath: String
    let runner: LocalRunner
    var vmrun: VMRun { VMRun(runner: runner, vmrunPath: vmrunPath) }

    init() throws {
        let fm = FileManager.default
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        home = URL(fileURLWithPath: String(cString: tmp)).appending(path: "vmdeck-auto-\(UUID().uuidString)")
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

    private func install(_ config: AutoStartConfig) async throws -> String {
        var argv = ["/bin/sh", "-c", AutoStartManager.installScript, "t", vmrunPath,
                    String(config.waitSeconds), String(config.staggerSeconds), "0",
                    AutoStartManager.runnerScript] + config.vmxPaths
        let r = try await runner.run(argv, timeout: .seconds(20))
        try VMRun.check(r)
        argv.removeAll()
        return r.stdout
    }

    private func makeVM(_ name: String) throws -> String {
        let dir = home.appending(path: "Virtual Machines.localized/\(name).vmwarevm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vmx = dir.appending(path: "\(name).vmx")
        try "displayName = \"\(name)\"\n".write(to: vmx, atomically: true, encoding: .utf8)
        return vmx.path
    }

    @Test func installWritesListScriptAndPlistThenUninstallRemovesThem() async throws {
        let a = try makeVM("A"), b = try makeVM("B")
        _ = try await install(AutoStartConfig(vmxPaths: [b, a], waitSeconds: 120, staggerSeconds: 3))

        let support = home.appending(path: "Library/Application Support/VMDeck")
        let list = try String(contentsOf: support.appending(path: "autostart.list"), encoding: .utf8)
        #expect(list == "120 3\n\(vmrunPath)\n\(b)\n\(a)\n")
        let script = try String(contentsOf: support.appending(path: "autostart.sh"), encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("auto-start begins"))
        let plist = home.appending(path: "Library/LaunchAgents/\(AutoStartManager.label).plist")
        let lint = try await runner.run(["/usr/bin/plutil", "-lint", plist.path], timeout: .seconds(5))
        #expect(lint.status == 0)
        let dict = try #require(NSDictionary(contentsOf: plist))
        #expect(dict["Label"] as? String == AutoStartManager.label)
        #expect((dict["ProgramArguments"] as? [String])?.last == support.appending(path: "autostart.sh").path)
        #expect(dict["RunAtLoad"] as? Bool == true)

        // Status reads it back, and discovery marks the VMs.
        let status = AutoStartManager.parseStatus(
            try await runner.run(["/bin/sh", "-c", AutoStartManager.statusScript, "t"], timeout: .seconds(10)).stdout)
        #expect(status.installed)
        #expect(status.config == AutoStartConfig(vmxPaths: [b, a], waitSeconds: 120, staggerSeconds: 3))
        let vms = try await Discovery(vmrun: vmrun).discover().vms
        #expect(vms.allSatisfy { $0.autoStart })

        _ = try await install(AutoStartConfig())
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "autostart.list").path))
        let after = try await Discovery(vmrun: vmrun).discover().vms
        #expect(!after.contains { $0.autoStart })
    }

    @Test func runnerWaitsForLateVolumesSkipsRunningAndStartsInOrder() async throws {
        let a = try makeVM("Early")
        let running = try makeVM("AlreadyOn")
        try await vmrun.start(running)
        // "Late" lives on a volume that hasn't mounted: its file doesn't exist yet.
        let lateDir = home.appending(path: "Volumes/RAID/Late.vmwarevm")
        let late = lateDir.appending(path: "Late.vmx").path
        let never = home.appending(path: "Volumes/Gone/Never.vmwarevm/Never.vmx").path

        _ = try await install(AutoStartConfig(vmxPaths: [a, running, late, never], waitSeconds: 8, staggerSeconds: 1))
        let script = home.appending(path: "Library/Application Support/VMDeck/autostart.sh").path

        // Mount the "volume" 2 s in.
        Task {
            try await Task.sleep(for: .seconds(2))
            try FileManager.default.createDirectory(at: lateDir, withIntermediateDirectories: true)
            try "displayName = \"Late\"\n".write(to: URL(fileURLWithPath: late), atomically: true, encoding: .utf8)
        }
        let start = ContinuousClock.now
        let r = try await runner.run(["/bin/sh", script], timeout: .seconds(60))
        #expect(r.status == 0)
        let elapsed = ContinuousClock.now - start
        // Waited for Late (≈2 s) and gave up on Never after 8 s, no longer.
        #expect(elapsed > .seconds(9) && elapsed < .seconds(30))

        #expect(Set(try await vmrun.list()) == [a, running, late])
        let log = try String(contentsOf: home.appending(path: "Library/Logs/VMDeck/autostart.log"), encoding: .utf8)
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.contains("Early: started"))
        #expect(lines.contains("AlreadyOn: already running"))
        #expect(lines.contains { $0.hasPrefix("Late: waiting for") })
        #expect(lines.contains("Late: started"))
        #expect(lines.contains("Never: still missing after 8s, skipped"))
        // Order: Early before Late.
        let iEarly = try #require(lines.firstIndex(of: "Early: started"))
        let iLate = try #require(lines.firstIndex(of: "Late: started"))
        #expect(iEarly < iLate)
    }
}
