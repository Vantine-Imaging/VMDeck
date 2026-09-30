import CryptoKit
import Foundation

/// The steps of getting a Mac VMDeck has never talked to ready for key-based
/// SSH: probe what's wrong, trust its host key, create and install a key.
struct SSHSetup: Sendable {
    /// Where VMDeck's own key lives. ~/.ssh in the app; a fixture dir in tests.
    var sshDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
    /// nil means ssh's default (~/.ssh/known_hosts). Tests point it elsewhere.
    var knownHostsFile: URL? = nil

    static let keyName = "vmdeck_ed25519"
    var privateKeyURL: URL { sshDirectory.appending(path: Self.keyName) }
    var publicKeyURL: URL { sshDirectory.appending(path: Self.keyName + ".pub") }
    var effectiveKnownHosts: URL { knownHostsFile ?? sshDirectory.appending(path: "known_hosts") }

    // MARK: - Probe

    enum Probe: Equatable, Sendable {
        case ok
        case unresolved
        case refused
        case unreachable(String)
        case unknownHostKey
        case hostKeyChanged
        case authFailed
        case other(String)
    }

    /// One ssh attempt that never prompts and never reuses a multiplexed
    /// connection, so a success proves auth really works on its own.
    /// With `identity`, only that key is offered.
    func probe(_ target: SSHTarget, identity: URL? = nil) async -> Probe {
        var options = [
            "BatchMode=yes", "ConnectTimeout=6", "StrictHostKeyChecking=yes",
            "ControlMaster=no", "ControlPath=none",
        ]
        if identity != nil { options.append("IdentitiesOnly=yes") }
        var args = sshOptions(options) + ["-p", String(target.port)]
        if let identity { args += ["-i", identity.path] }
        args += [target.destination, "--", "/usr/bin/true"]
        do {
            let result = try await ProcessExec.run(executable: "/usr/bin/ssh", arguments: args, timeout: .seconds(15))
            return Self.classify(result)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func classify(_ result: CommandResult) -> Probe {
        if result.status == 0 { return .ok }
        let err = result.stderr.lowercased()
        let has = { (s: String) in err.contains(s) }
        if has("could not resolve hostname") { return .unresolved }
        if has("connection refused") { return .refused }
        if has("timed out") || has("no route to host") || has("host is down") || has("network is unreachable") {
            return .unreachable(lastLine(result.stderr))
        }
        // Checked before "verification failed", which ssh prints for both.
        if has("remote host identification has changed") { return .hostKeyChanged }
        if has("host key verification failed") || (has("host key") && has("is known")) { return .unknownHostKey }
        if has("permission denied") || has("too many authentication failures") { return .authFailed }
        return .other(lastLine(result.stderr).isEmpty ? "ssh exited with status \(result.status)." : lastLine(result.stderr))
    }

    private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    // MARK: - Host keys

    struct HostKey: Hashable, Sendable {
        /// The known_hosts line exactly as ssh-keyscan printed it.
        let line: String
        let type: String
        let fingerprint: String
    }

    func scanHostKeys(_ target: SSHTarget) async throws -> [HostKey] {
        let result = try await ProcessExec.run(
            executable: "/usr/bin/ssh-keyscan",
            arguments: ["-T", "5", "-p", String(target.port), target.hostname],
            timeout: .seconds(15))
        let keys = Self.parseKeyscan(result.stdout)
        guard !keys.isEmpty else {
            throw VMRunError.failed("Couldn't read \(target.hostname)'s host key.")
        }
        return keys
    }

    static func parseKeyscan(_ output: String) -> [HostKey] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let blob = Data(base64Encoded: String(parts[2])) else { return nil }
            return HostKey(line: line, type: String(parts[1]), fingerprint: fingerprint(of: blob))
        }
        .sorted { rank($0.type) < rank($1.type) }
    }

    /// Same format ssh-keygen -l prints: SHA256, base64, no padding.
    static func fingerprint(of blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    private static func rank(_ type: String) -> Int {
        switch type {
        case "ssh-ed25519": 0
        case let t where t.hasPrefix("ecdsa"): 1
        default: 2
        }
    }

    func trust(_ keys: [HostKey]) throws {
        let fm = FileManager.default
        let file = effectiveKnownHosts
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        let existing = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        for key in keys where !existing.contains(key.line) {
            text += key.line + "\n"
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: - Client key

    /// VMDeck's key, created on first use. It has no passphrase because the
    /// app connects in the background every few seconds with nobody to type one.
    func ensureKey() async throws -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: privateKeyURL.path) {
            try fm.createDirectory(at: sshDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let comment = "VMDeck@\(ProcessInfo.processInfo.hostName)"
            let result = try await ProcessExec.run(
                executable: "/usr/bin/ssh-keygen",
                arguments: ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", privateKeyURL.path],
                timeout: .seconds(15))
            guard result.status == 0 else {
                throw VMRunError.failed("ssh-keygen failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return try String(contentsOf: publicKeyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Install

    /// Appends `publicKey` to the remote user's authorized_keys, signing in
    /// with `password` this one time. The password reaches ssh through a
    /// throwaway SSH_ASKPASS helper and the child's environment; it's never
    /// written to disk or kept.
    func installKey(_ publicKey: String, on target: SSHTarget, password: String) async throws {
        let fm = FileManager.default
        let helperDir = fm.temporaryDirectory.appending(path: "vmdeck-askpass-\(UUID().uuidString)")
        try fm.createDirectory(at: helperDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: helperDir) }
        let helper = helperDir.appending(path: "askpass")
        try Self.askpassScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env[Self.askpassVariable] = password

        let options = [
            "PubkeyAuthentication=no", "PreferredAuthentications=keyboard-interactive,password",
            "NumberOfPasswordPrompts=1", "StrictHostKeyChecking=yes", "ConnectTimeout=8",
            // Never leave a password-authenticated master behind: later probes
            // would ride it and "prove" key auth that doesn't exist.
            "ControlMaster=no", "ControlPath=none",
        ]
        let remote = ["/bin/sh", "-c", Self.installScript, "vmdeck-install", publicKey]
        let args = sshOptions(options) + ["-p", String(target.port), target.destination, "--"]
            + [remote.map(shellQuote).joined(separator: " ")]
        let result = try await ProcessExec.run(executable: "/usr/bin/ssh", arguments: args,
                                               environment: env, timeout: .seconds(30))
        guard result.status == 0 else {
            switch Self.classify(result) {
            case .authFailed:
                throw VMRunError.failed("\(target.destination) rejected that password. Check the password, and that this user is allowed under Remote Login on that Mac.")
            case .unknownHostKey, .hostKeyChanged:
                throw VMRunError.failed("The host key isn't trusted yet. Go back and trust it first.")
            default:
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw VMRunError.failed(detail.isEmpty ? "Installing the key failed (status \(result.status))." : detail)
            }
        }
    }

    static let askpassVariable = "VMDECK_ASKPASS_SECRET"
    static let askpassScript = "#!/bin/sh\nprintf '%s\\n' \"$\(askpassVariable)\"\n"

    /// $1 is the public key line. Idempotent, and fixes up a missing trailing
    /// newline so the key doesn't get glued onto the previous one.
    static let installScript = #"""
    umask 077
    d="$HOME/.ssh"; f="$d/authorized_keys"
    mkdir -p "$d" && touch "$f" && chmod 700 "$d" && chmod 600 "$f" || exit 1
    grep -qxF "$1" "$f" && exit 0
    [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ] && printf '\n' >> "$f"
    printf '%s\n' "$1" >> "$f"
    """#

    /// A Terminal command that does the same as installKey, for people who'd
    /// rather type their password into ssh itself.
    func terminalCommand(for target: SSHTarget) -> String {
        var words = ["ssh-copy-id", "-i", "~/.ssh/\(Self.keyName).pub"]
        if target.port != 22 { words += ["-p", String(target.port)] }
        words.append(target.destination)
        return words.map { $0.hasPrefix("~/") ? $0 : shellQuote($0) }.joined(separator: " ")
    }

    // MARK: -

    private func sshOptions(_ options: [String]) -> [String] {
        var all = options
        if let knownHostsFile { all.append("UserKnownHostsFile=\"\(knownHostsFile.path)\"") }
        return all.flatMap { ["-o", $0] }
    }
}

extension SSHTarget {
    var destination: String { user.isEmpty ? hostname : "\(user)@\(hostname)" }
}
