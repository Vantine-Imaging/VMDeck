import Foundation

struct LocalRunner: CommandRunner {
    /// Replaces the inherited environment when set. Used by tests to point
    /// HOME at a fixture directory.
    var environment: [String: String]? = nil

    func run(_ argv: [String], timeout: Duration) async throws -> CommandResult {
        guard let executable = argv.first else {
            throw CommandError.launchFailed("empty command")
        }
        return try await ProcessExec.run(
            executable: executable,
            arguments: Array(argv.dropFirst()),
            environment: environment,
            timeout: timeout
        )
    }
}
