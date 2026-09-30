import Foundation

enum VMRunError: LocalizedError, Equatable {
    /// vmrun ran and reported a failure ("Error: …" on stdout).
    case vmrun(String)
    /// The command didn't get as far as vmrun: ssh couldn't connect, vmrun is
    /// missing, and so on.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .vmrun(let message), .failed(let message): message
        }
    }
}

/// Typed wrappers over `vmrun -T fusion`. The same calls work locally and over
/// SSH because only the runner differs.
struct VMRun: Sendable {
    let runner: any CommandRunner
    let vmrunPath: String

    static let quickTimeout: Duration = .seconds(10)
    /// Soft stop waits for the guest OS to shut down, which can take a while.
    static let lifecycleTimeout: Duration = .seconds(180)

    /// Paths of running VMs, exactly as vmrun reports them.
    func list() async throws -> [String] {
        let output = try await vmrun(["list"], timeout: Self.quickTimeout)
        return Self.parseList(output)
    }

    func start(_ vmx: String) async throws {
        _ = try await vmrun(["start", vmx, "nogui"], timeout: Self.lifecycleTimeout)
    }

    /// A soft stop returns only once the guest has powered off, and Windows
    /// installing updates can take many minutes.
    static let softStopTimeout: Duration = .seconds(900)

    func stop(_ vmx: String, hard: Bool) async throws {
        _ = try await vmrun(["stop", vmx, hard ? "hard" : "soft"],
                            timeout: hard ? Self.lifecycleTimeout : Self.softStopTimeout)
    }

    func suspend(_ vmx: String) async throws {
        _ = try await vmrun(["suspend", vmx], timeout: Self.lifecycleTimeout)
    }

    /// Soft reset needs VMware Tools in the guest. The user has already
    /// confirmed the reset, so fall back to a hard reset rather than failing.
    func reset(_ vmx: String) async throws {
        do {
            _ = try await vmrun(["reset", vmx, "soft"], timeout: Self.lifecycleTimeout)
        } catch VMRunError.vmrun {
            _ = try await vmrun(["reset", vmx, "hard"], timeout: Self.lifecycleTimeout)
        }
    }

    /// vmrun's getGuestIPAddress can print "unknown" and exit 0 while a guest
    /// boots or shuts down, and discovery reads guestinfo.ip directly, so
    /// every address goes through this before it's shown.
    static func isIPAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// Size of the VM's bundle on disk, in bytes.
    func diskUsage(_ vmx: String) async throws -> Int64 {
        let dir = URL(fileURLWithPath: vmx).deletingLastPathComponent().path
        let result = try await runner.run(["/usr/bin/du", "-sk", dir], timeout: .seconds(30))
        guard result.status == 0, let kb = result.stdout.split(separator: "\t").first.flatMap({ Int64($0) }) else {
            throw VMRunError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return kb * 1024
    }

    // MARK: -

    private func vmrun(_ args: [String], timeout: Duration) async throws -> String {
        let argv = ["/bin/sh", "-c", Self.detachedScript, "vmdeck-vmrun", vmrunPath, "-T", "fusion"] + args
        let result = try await runner.run(argv, timeout: timeout)
        try Self.check(result)
        return result.stdout
    }

    /// Runs "$@" with its output going to a temp file on the host, then prints
    /// that file. `vmrun start` leaves vmware-vmx running with vmrun's stdout
    /// and stderr, and over SSH those are the session's channel: ssh waits for
    /// every holder to close them, so a headless start never returned until
    /// the VM stopped. The VM now holds a temp file instead.
    static let detachedScript = #"""
    out=$(mktemp -t vmdeck) || exit 1
    "$@" >"$out" 2>&1 </dev/null
    rc=$?
    cat "$out"
    rm -f "$out"
    exit $rc
    """#

    /// vmrun prints its errors to stdout and exits 255; ssh prints its errors
    /// to stderr and also exits 255. The "Error:" prefix tells them apart.
    static func check(_ result: CommandResult) throws {
        if let line = result.stdout.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Error:") }) {
            throw VMRunError.vmrun(line.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces))
        }
        guard result.status == 0 else {
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            throw VMRunError.failed(detail ?? "Command exited with status \(result.status).")
        }
    }

    static func parseList(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("Total running VMs") && !$0.isEmpty }
    }
}
