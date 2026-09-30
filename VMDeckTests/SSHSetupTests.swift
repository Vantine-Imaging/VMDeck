import Foundation
import Testing
@testable import VMDeck

@Suite struct SSHProbeClassificationTests {
    private func classify(_ stderr: String, status: Int32 = 255) -> SSHSetup.Probe {
        SSHSetup.classify(CommandResult(status: status, stdout: "", stderr: stderr))
    }

    @Test func classifiesCommonFailures() {
        #expect(classify("", status: 0) == .ok)
        #expect(classify("ssh: Could not resolve hostname nope.local: nodename nor servname provided, or not known") == .unresolved)
        #expect(classify("ssh: connect to host mini.local port 22: Connection refused") == .refused)
        #expect(classify("ssh: connect to host 10.0.0.9 port 22: Operation timed out")
                == .unreachable("ssh: connect to host 10.0.0.9 port 22: Operation timed out"))
        #expect(classify("No ED25519 host key is known for mini.local and you have requested strict checking.\nHost key verification failed.") == .unknownHostKey)
        #expect(classify("@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n...\nHost key verification failed.") == .hostKeyChanged)
        #expect(classify("alec@mini.local: Permission denied (publickey,password,keyboard-interactive).") == .authFailed)
        #expect(classify("kex_exchange_identification: read: Connection reset by peer") == .other("kex_exchange_identification: read: Connection reset by peer"))
    }

    @Test func terminalCommandQuotesTheDestination() {
        let setup = SSHSetup()
        #expect(setup.terminalCommand(for: SSHTarget(user: "alec", hostname: "mini.local"))
                == "ssh-copy-id -i ~/.ssh/vmdeck_ed25519.pub alec@mini.local")
        #expect(setup.terminalCommand(for: SSHTarget(user: "o'neil", hostname: "mini.local", port: 2222))
                == #"ssh-copy-id -i ~/.ssh/vmdeck_ed25519.pub -p 2222 'o'\''neil@mini.local'"#)
    }

    @Test func askpassHelperPrintsTheSecret() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vmdeck-askpass-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appending(path: "askpass")
        try SSHSetup.askpassScript.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        var env = ProcessInfo.processInfo.environment
        env[SSHSetup.askpassVariable] = #"p@ss w'rd $x"#
        let result = try await ProcessExec.run(executable: helper.path, arguments: ["Password:"],
                                               environment: env, timeout: .seconds(5))
        #expect(result.stdout == "p@ss w'rd $x\n")
    }
}

/// Talks to a real, private sshd on loopback: an unprivileged sshd on a high
/// port, with its own host key and authorized_keys, running as the current
/// user. Nothing touches ~/.ssh.
@Suite(.serialized) final class SSHSetupEndToEndTests {
    let root: URL
    let port: Int
    let setup: SSHSetup
    let remoteHome: URL
    var sshd: Process?

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "vmdeck-sshd-\(UUID().uuidString)")
        remoteHome = root.appending(path: "remote-home")
        try fm.createDirectory(at: remoteHome, withIntermediateDirectories: true)
        port = Int.random(in: 30000...60000)
        setup = SSHSetup(sshDirectory: root.appending(path: "client-ssh"),
                         knownHostsFile: root.appending(path: "known_hosts"))
    }

    deinit {
        sshd?.terminate()
        try? FileManager.default.removeItem(at: root)
    }

    var target: SSHTarget { SSHTarget(user: NSUserName(), hostname: "127.0.0.1", port: port) }

    private func run(_ exe: String, _ args: [String], env: [String: String]? = nil) async throws -> CommandResult {
        try await ProcessExec.run(executable: exe, arguments: args, environment: env, timeout: .seconds(15))
    }

    private func startSSHD() async throws {
        let hostKey = root.appending(path: "hostkey").path
        _ = try await run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
        let config = root.appending(path: "sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        AuthorizedKeysFile \(remoteHome.path)/.ssh/authorized_keys
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        PidFile \(root.path)/sshd.pid
        SetEnv FAKE_VMRUN_STATE=\(root.path)/fake-running
        """.write(to: config, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-f", config.path, "-E", root.appending(path: "sshd.log").path]
        try process.run()
        sshd = process
        // Wait for it to accept connections.
        for _ in 0..<50 {
            let scan = try await run("/usr/bin/ssh-keyscan", ["-T", "1", "-p", String(port), "127.0.0.1"])
            if !scan.stdout.isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("sshd didn't start")
    }

    @Test func freshMacFlowThroughKeySignIn() async throws {
        try await startSSHD()

        // 1. Never seen: the host key is unknown.
        #expect(await setup.probe(target) == .unknownHostKey)

        // 2. Scan shows the same fingerprint ssh-keygen computes on the server.
        let keys = try await setup.scanHostKeys(target)
        let serverPrint = try await run("/usr/bin/ssh-keygen", ["-lf", root.appending(path: "hostkey.pub").path])
        let ed = try #require(keys.first)
        #expect(ed.type == "ssh-ed25519")
        #expect(serverPrint.stdout.contains(ed.fingerprint))

        // Trusting twice doesn't duplicate lines.
        try setup.trust(keys)
        try setup.trust(keys)
        let known = try String(contentsOf: setup.effectiveKnownHosts, encoding: .utf8)
        #expect(known.split(whereSeparator: \.isNewline).count == keys.count)

        // 3. Trusted but no key installed.
        #expect(await setup.probe(target, identity: setup.privateKeyURL) == .authFailed)

        // 4. Create VMDeck's key; run the real install script as the "remote"
        // user would (twice, to prove it's idempotent), against a file that
        // lacks a trailing newline.
        let publicKey = try await setup.ensureKey()
        #expect(publicKey.hasPrefix("ssh-ed25519 "))
        try FileManager.default.createDirectory(at: remoteHome.appending(path: ".ssh"), withIntermediateDirectories: true)
        try "ssh-ed25519 AAAAexisting other@key".write(
            to: remoteHome.appending(path: ".ssh/authorized_keys"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = remoteHome.path
        for _ in 0..<2 {
            let install = try await run("/bin/sh", ["-c", SSHSetup.installScript, "vmdeck-install", publicKey], env: env)
            #expect(install.status == 0)
        }
        let authorized = try String(contentsOf: remoteHome.appending(path: ".ssh/authorized_keys"), encoding: .utf8)
        #expect(authorized == "ssh-ed25519 AAAAexisting other@key\n\(publicKey)\n")

        // 5. Key sign-in works, and the regular runner uses it end to end.
        #expect(await setup.probe(target, identity: setup.privateKeyURL) == .ok)
        var withKey = target
        withKey.identityFile = setup.privateKeyURL.path
        let runner = SSHRunner(target: withKey, extraOptions: [
            "UserKnownHostsFile=\"\(setup.effectiveKnownHosts.path)\"", "ControlPath=none",
        ])
        let echo = try await runner.run(["/bin/echo", "a b", "it's", "$HOME"], timeout: .seconds(10))
        #expect(echo.stdout == "a b it's $HOME\n")
    }

    /// Regression: `vmrun start` over SSH hung until the VM stopped, because
    /// vmware-vmx kept the session's stdout open and ssh waits for it.
    @Test func headlessStartOverSSHReturnsPromptly() async throws {
        try await startSSHD()
        let publicKey = try await setup.ensureKey()
        try FileManager.default.createDirectory(at: remoteHome.appending(path: ".ssh"), withIntermediateDirectories: true)
        try (publicKey + "\n").write(to: remoteHome.appending(path: ".ssh/authorized_keys"), atomically: true, encoding: .utf8)
        try setup.trust(try await setup.scanHostKeys(target))

        let fake = root.appending(path: "fake-vmrun")
        let bundled = try #require(Bundle(for: SSHSetupEndToEndTests.self).url(forResource: "fake-vmrun", withExtension: nil))
        try FileManager.default.copyItem(at: bundled, to: fake)
        let vmDir = root.appending(path: "VM.vmwarevm")
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        let vmx = vmDir.appending(path: "VM.vmx")
        try "displayName = \"VM\"\n".write(to: vmx, atomically: true, encoding: .utf8)

        var withKey = target
        withKey.identityFile = setup.privateKeyURL.path
        let runner = SSHRunner(target: withKey, extraOptions: [
            "UserKnownHostsFile=\"\(setup.effectiveKnownHosts.path)\"", "ControlPath=none",
        ])
        let vmrun = VMRun(runner: runner, vmrunPath: fake.path)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure { try await vmrun.start(vmx.path) }
        // The fake's lingering child lives 8 s; without the fix this takes that long.
        #expect(elapsed < .seconds(4))
        #expect(try await vmrun.list() == [vmx.path])
    }

    @Test func changedHostKeyIsDetected() async throws {
        try await startSSHD()
        // known_hosts holds a different key for this host:port.
        _ = try await run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", root.appending(path: "other").path])
        let otherKey = try String(contentsOf: root.appending(path: "other.pub"), encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")
        try "[127.0.0.1]:\(port) \(otherKey)\n".write(to: setup.effectiveKnownHosts, atomically: true, encoding: .utf8)
        #expect(await setup.probe(target) == .hostKeyChanged)
    }

    @Test func refusedAndUnresolved() async throws {
        // Nothing listening on this port: Remote Login is "off".
        #expect(await setup.probe(target) == .refused)
        #expect(await setup.probe(SSHTarget(user: "x", hostname: "no-such-mac.invalid")) == .unresolved)
    }
}
