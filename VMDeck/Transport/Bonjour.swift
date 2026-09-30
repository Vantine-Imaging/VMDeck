import Foundation
import Network
import Observation
import SystemConfiguration
import dnssd

/// Macs with Remote Login turned on advertise `_ssh._tcp` over Bonjour, so this
/// lists exactly the machines that are ready for the next setup step.
@MainActor
@Observable
final class SSHServiceBrowser {
    private(set) var names: [String] = []
    private(set) var failure: String?

    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }
            // This Mac advertises itself too when Remote Login is on.
            let me = SCDynamicStoreCopyComputerName(nil, nil) as String?
            let others = Set(names).filter { $0 != me }
            Task { @MainActor in
                self?.names = others.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let message: String? = switch state {
            case .failed(let error), .waiting(let error): error.localizedDescription
            default: nil
            }
            Task { @MainActor in self?.failure = message }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

enum BonjourResolver {
    /// Turns a Bonjour service name ("Alec's Mac mini") into the hostname ssh
    /// needs ("Alecs-Mac-mini.local") and its port.
    static func resolveSSH(_ name: String) async -> (hostname: String, port: Int)? {
        await withCheckedContinuation { continuation in
            let request = ResolveRequest(continuation)
            request.start(name: name)
        }
    }
}

/// Owns one DNSServiceResolve call. Everything runs on `queue`, which is what
/// makes the unchecked Sendable safe.
private final class ResolveRequest: @unchecked Sendable {
    typealias Result = (hostname: String, port: Int)?

    private let queue = DispatchQueue(label: "com.vantine.VMDeck.resolve")
    private var continuation: CheckedContinuation<Result, Never>?
    private var ref: DNSServiceRef?

    init(_ continuation: CheckedContinuation<Result, Never>) {
        self.continuation = continuation
    }

    func start(name: String) {
        queue.async { [self] in
            // Balanced by the release in finish().
            let context = Unmanaged.passRetained(self).toOpaque()
            let callback: DNSServiceResolveReply = { _, _, _, error, _, hostTarget, port, _, _, context in
                guard let context else { return }
                let request = Unmanaged<ResolveRequest>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError, let hostTarget else {
                    request.finish(nil)
                    return
                }
                var host = String(cString: hostTarget)
                if host.hasSuffix(".") { host.removeLast() }
                request.finish((host, Int(UInt16(bigEndian: port))))
            }
            let status = DNSServiceResolve(&ref, 0, 0, name, "_ssh._tcp", "local.", callback, context)
            guard status == kDNSServiceErr_NoError, let ref else {
                finish(nil)
                return
            }
            DNSServiceSetDispatchQueue(ref, queue)
            queue.asyncAfter(deadline: .now() + 5) { [self] in finish(nil) }
        }
    }

    private func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
        continuation.resume(returning: result)
        Unmanaged.passUnretained(self).release()
    }
}
