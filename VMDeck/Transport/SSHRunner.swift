import Foundation

/// Runs commands on a remote Mac with the system ssh client, so the user's
/// ~/.ssh/config, keys, and agent all apply. BatchMode means ssh never prompts:
/// a host without key auth fails fast with a readable error instead of hanging.
struct SSHRunner: CommandRunner {
    let target: SSHTarget
    /// Extra `-o` options. Tests use it to keep a private known_hosts file.
    var extraOptions: [String] = []

    func run(_ argv: [String], timeout: Duration) async throws -> CommandResult {
        guard !argv.isEmpty else { throw CommandError.launchFailed("empty command") }
        return try await ProcessExec.run(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(for: target, remoteArgv: argv, extraOptions: extraOptions),
            timeout: timeout
        )
    }

    static func sshArguments(for target: SSHTarget, remoteArgv: [String], extraOptions: [String] = []) -> [String] {
        var args = extraOptions.flatMap { ["-o", $0] } + [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            // Trust a host key on first use, refuse if it later changes.
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR",
            // One TCP+auth handshake shared across the 5 s polls.
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory.path)/%C",
            "-o", "ControlPersist=60",
            "-p", String(target.port),
        ]
        if let identity = target.identityFile {
            args += ["-i", identity]
        }
        args.append(target.destination)
        args.append("--")
        // ssh joins its trailing arguments with spaces and hands the result to
        // the remote login shell, so every word must survive that shell intact.
        args.append(remoteArgv.map(shellQuote).joined(separator: " "))
        return args
    }

    /// Short and private: Unix socket paths are capped at 104 bytes and %C
    /// alone expands to 40.
    static let controlDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "VMDeck/ssh", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()
}

/// POSIX single-quote quoting; valid for sh, bash, and zsh.
func shellQuote(_ word: String) -> String {
    if !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "/._-=:@%+,".contains($0) }),
       word.unicodeScalars.allSatisfy(\.isASCII) {
        return word
    }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
