import Foundation

struct SSHTarget: Codable, Hashable, Sendable {
    var user: String
    var hostname: String
    var port: Int = 22
    /// Key the SSH setup assistant installed. nil: ssh's own defaults and
    /// ~/.ssh/config decide.
    var identityFile: String? = nil
}

struct Host: Identifiable, Codable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case local
        case ssh(SSHTarget)
    }

    static let defaultVMRunPath = "/Applications/VMware Fusion.app/Contents/Library/vmrun"

    var id = UUID()
    var name: String
    var kind: Kind
    var vmrunPath: String = Host.defaultVMRunPath
    /// .vmx files outside the folders VMDeck scans on its own.
    var extraVMXPaths: [String] = []

    var subtitle: String {
        switch kind {
        case .local:
            return "This Mac"
        case .ssh(let t):
            return t.port == 22 ? t.destination : "\(t.destination):\(t.port)"
        }
    }

    var systemImage: String {
        switch kind {
        case .local: "laptopcomputer"
        case .ssh: "server.rack"
        }
    }

    func makeRunner() -> any CommandRunner {
        switch kind {
        case .local: LocalRunner()
        case .ssh(let target): SSHRunner(target: target)
        }
    }

    var vmrun: VMRun { VMRun(runner: makeRunner(), vmrunPath: vmrunPath) }
}
