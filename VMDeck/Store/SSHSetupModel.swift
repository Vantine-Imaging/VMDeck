import Foundation
import Observation

@MainActor
@Observable
final class SSHSetupModel {
    enum Step: Int, CaseIterable, Identifiable {
        case find, trust, key, fusion
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .find: "Find Mac"
            case .trust: "Trust"
            case .key: "Sign-in Key"
            case .fusion: "Fusion"
            }
        }
    }

    struct Problem: Equatable {
        var text: String
        var hint: String?
        var command: String?
    }

    struct FusionCheck: Equatable {
        var runningCount: Int?
        var error: String?
        var documentsBlocked = false
    }

    var step: Step = .find
    var hostname = ""
    var user = NSUserName()
    var port = 22
    var name = ""
    var vmrunPath = Host.defaultVMRunPath
    var password = ""

    private(set) var busy = false
    private(set) var problem: Problem?
    private(set) var hostKeys: [SSHSetup.HostKey] = []
    private(set) var fusion: FusionCheck?
    /// Set when VMDeck's own key is what signs in, rather than one of the
    /// user's existing keys.
    private(set) var identity: String?

    let original: Host?
    @ObservationIgnored let setup: SSHSetup

    init(original: Host?, setup: SSHSetup = SSHSetup()) {
        self.original = original
        self.setup = setup
        if let original, case .ssh(let t) = original.kind {
            hostname = t.hostname
            user = t.user
            port = t.port
            identity = t.identityFile
            name = original.name
            vmrunPath = original.vmrunPath
        }
    }

    var target: SSHTarget {
        SSHTarget(user: user.trimmed, hostname: hostname.trimmed, port: port, identityFile: identity)
    }

    var canCheck: Bool { !hostname.trimmed.isEmpty && (1...65535).contains(port) && !busy }

    // MARK: - Steps

    func useNearby(_ serviceName: String) async {
        busy = true
        defer { busy = false }
        problem = nil
        guard let resolved = await BonjourResolver.resolveSSH(serviceName) else {
            problem = Problem(text: "Couldn't look up \(serviceName). Try entering its hostname instead.")
            return
        }
        hostname = resolved.hostname
        port = resolved.port
        if name.trimmed.isEmpty { name = serviceName }
    }

    /// Figures out what the Mac needs and moves to that step.
    func checkConnection() async {
        busy = true
        defer { busy = false }
        problem = nil

        var result = await setup.probe(SSHTarget(user: user.trimmed, hostname: hostname.trimmed, port: port))
        if result == .ok {
            identity = nil
        } else if result == .authFailed, FileManager.default.fileExists(atPath: setup.privateKeyURL.path) {
            // Maybe VMDeck's key is already installed there from a previous setup.
            if await setup.probe(target, identity: setup.privateKeyURL) == .ok {
                identity = setup.privateKeyURL.path
                result = .ok
            }
        }

        let host = hostname.trimmed
        switch result {
        case .ok:
            step = .fusion
            await runFusionCheck()
        case .unknownHostKey:
            do {
                hostKeys = try await setup.scanHostKeys(target)
                step = .trust
            } catch {
                problem = Problem(text: error.localizedDescription)
            }
        case .authFailed:
            await enterKeyStep()
        case .hostKeyChanged:
            problem = Problem(
                text: "\(host)'s host key doesn't match the one this Mac saw before.",
                hint: "That's expected if the Mac was reinstalled or replaced. Otherwise, something may be impersonating it. Once you're sure it's the right Mac, forget the old key in Terminal and check again:",
                command: "ssh-keygen -R \(shellQuote(port == 22 ? host : "[\(host)]:\(port)"))")
        case .unresolved:
            problem = Problem(
                text: "Couldn't find a Mac named \(host).",
                hint: "Check the spelling. A Mac's local hostname ends in .local and is shown at the bottom of System Settings > General > Sharing on that Mac.")
        case .refused:
            problem = Problem(
                text: "\(host) is on the network, but Remote Login is off.",
                hint: "On that Mac, open System Settings > General > Sharing and turn on Remote Login.")
        case .unreachable(let detail):
            problem = Problem(
                text: "Couldn't reach \(host).",
                hint: "Make sure it's awake and on the same network, or reachable over your VPN. (\(detail))")
        case .other(let detail):
            problem = Problem(text: detail)
        }
    }

    func trustAndContinue() async {
        do {
            try setup.trust(hostKeys)
        } catch {
            problem = Problem(text: "Couldn't save the host key: \(error.localizedDescription)")
            return
        }
        await checkConnection()
    }

    private func enterKeyStep() async {
        do {
            // Created now so the Terminal alternative has a key to copy.
            _ = try await setup.ensureKey()
            step = .key
        } catch {
            problem = Problem(text: error.localizedDescription)
        }
    }

    func installKey() async {
        busy = true
        defer { busy = false }
        problem = nil
        do {
            let publicKey = try await setup.ensureKey()
            let secret = password
            password = ""
            try await setup.installKey(publicKey, on: SSHTarget(user: user.trimmed, hostname: hostname.trimmed, port: port),
                                       password: secret)
        } catch {
            problem = Problem(text: error.localizedDescription)
            return
        }
        await verifyKey(afterInstall: true)
    }

    /// For the Terminal route: the user ran ssh-copy-id and comes back.
    func verifyKey(afterInstall: Bool = false) async {
        busy = true
        defer { busy = false }
        problem = nil
        let result = await setup.probe(target, identity: setup.privateKeyURL)
        guard result == .ok else {
            problem = afterInstall
                ? Problem(text: "The key was installed, but signing in with it still fails.",
                          hint: "The remote Mac may have key sign-in turned off in /etc/ssh/sshd_config, or its ~/.ssh folder may be writable by other users.")
                : Problem(text: "Still can't sign in with VMDeck's key.",
                          hint: "Run the command below in Terminal, enter the password when asked, then check again.")
            return
        }
        identity = setup.privateKeyURL.path
        step = .fusion
        await runFusionCheck()
    }

    func runFusionCheck() async {
        busy = true
        defer { busy = false }
        problem = nil
        fusion = nil
        let runner = SSHRunner(target: target)
        var check = FusionCheck()
        do {
            check.runningCount = try await VMRun(runner: runner, vmrunPath: vmrunPath.trimmed).list().count
        } catch {
            check.error = error.localizedDescription
        }
        // Remote Login sessions can't read ~/Documents unless the remote Mac
        // grants them Full Disk Access, and older Fusion keeps VMs there.
        if let result = try? await runner.run(
            ["/bin/sh", "-c", #"[ ! -d "$HOME/Documents" ] || ls "$HOME/Documents" >/dev/null 2>&1 && echo ok || echo blocked"#],
            timeout: .seconds(10)) {
            check.documentsBlocked = result.stdout.contains("blocked")
        }
        fusion = check
    }

    func back() {
        problem = nil
        step = .find
    }

    func makeHost() -> Host {
        var host = original ?? Host(name: "", kind: .ssh(target))
        host.name = name.trimmed.isEmpty ? hostname.trimmed : name.trimmed
        host.kind = .ssh(target)
        host.vmrunPath = vmrunPath.trimmed
        return host
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
