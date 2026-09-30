import Foundation
import os

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum CommandError: LocalizedError {
    case timedOut(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let what): "Timed out waiting for \(what)."
        case .launchFailed(let why): "Couldn't run command: \(why)"
        }
    }
}

/// Runs an argv somewhere: on this Mac, or on a remote Mac over SSH.
/// argv[0] must be an absolute path on the machine the command runs on.
protocol CommandRunner: Sendable {
    func run(_ argv: [String], timeout: Duration) async throws -> CommandResult
}

enum ProcessExec {
    /// Runs a process to completion without blocking a cooperative thread.
    ///
    /// Output goes to temp files, not pipes, on purpose: `ssh -o ControlPersist`
    /// forks a background master that inherits the child's stdout/stderr. With
    /// pipes, reading to EOF would hang until that master exits (60 s). A file
    /// has no EOF to wait for, so we read it as soon as the direct child exits.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration
    ) async throws -> CommandResult {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "vmdeck-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let box = ProcessBox(process)
        let timer = DispatchWorkItem {
            timedOut.withLock { $0 = true }
            box.process.terminate()
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CommandError.launchFailed(error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds, execute: timer)
        }
        timer.cancel()

        if timedOut.withLock({ $0 }) {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw CommandError.timedOut(name)
        }
        let out = (try? Data(contentsOf: outURL)) ?? Data()
        let err = (try? Data(contentsOf: errURL)) ?? Data()
        return CommandResult(
            status: status,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }
}

/// Lets the timeout closure terminate the process. Process is thread-safe for
/// terminate(), it just isn't annotated Sendable.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
