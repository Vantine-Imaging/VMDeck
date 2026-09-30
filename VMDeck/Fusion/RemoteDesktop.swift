import AppKit
import Foundation

/// Opens a screen session to a running guest with whatever this Mac has
/// registered: an RDP client (Windows App) for Windows guests, Screen Sharing
/// for `vnc://` on the rest.
enum RemoteDesktop {
    enum Kind: Equatable, Sendable {
        case rdp, vnc

        var scheme: String { self == .rdp ? "rdp" : "vnc" }
        var name: String { self == .rdp ? "Remote Desktop (RDP)" : "Screen Sharing (VNC)" }
    }

    /// Windows guests speak RDP; everything else gets VNC, which macOS guests
    /// serve through Screen Sharing and most Linux desktops through their
    /// own VNC server.
    static func kind(forGuestOS guestOS: String?) -> Kind {
        (guestOS ?? "").lowercased().hasPrefix("windows") ? .rdp : .vnc
    }

    static func vncURL(ip: String) -> URL? {
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = ip
        return components.url
    }

    /// A minimal .rdp file. Windows App's `rdp://` URL form doesn't survive
    /// Foundation's URL parser, but every RDP client opens .rdp files.
    static func rdpFileContents(ip: String, name: String) -> String {
        let host = ip.contains(":") ? "[\(ip)]" : ip
        return """
        full address:s:\(host):3389
        prompt for credentials:i:1
        authentication level:i:2
        screen mode id:i:2
        desktopwidth:i:1920
        desktopheight:i:1080
        session bpp:i:32
        audiomode:i:0
        redirectclipboard:i:1
        alternate shell:s:
        remoteapplicationmode:i:0

        """
    }

    /// The app registered for the kind's URL scheme, or nil if none.
    @MainActor
    static func handler(for kind: Kind) -> URL? {
        guard let probe = URL(string: "\(kind.scheme)://probe") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    struct Target: Equatable, Sendable {
        var kind: Kind
        var ip: String
        var vmName: String
        var handler: URL?

        var handlerName: String? { handler?.deletingPathExtension().lastPathComponent }

        var help: String {
            if let handlerName {
                return "Open in \(handlerName) (\(kind.name))"
            }
            return kind == .rdp
                ? "No RDP client is installed. Get Windows App from the App Store."
                : "Nothing on this Mac can open vnc:// links."
        }
    }

    @MainActor
    static func target(for vm: VirtualMachine) -> Target? {
        guard vm.powerState == .running, let ip = vm.ipAddress else { return nil }
        let kind = kind(forGuestOS: vm.config.guestOS)
        return Target(kind: kind, ip: ip, vmName: vm.displayName, handler: handler(for: kind))
    }

    /// Where .rdp files go. Kept, not temporary, so the RDP client can reopen
    /// them from its own recents.
    static var connectionsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VMDeck/Connections")
    }

    @MainActor
    static func open(_ target: Target) throws {
        guard let app = target.handler else { return }
        switch target.kind {
        case .vnc:
            guard let url = vncURL(ip: target.ip) else { return }
            NSWorkspace.shared.open(url)
        case .rdp:
            let dir = connectionsDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = target.vmName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let file = dir.appending(path: "\(safeName).rdp")
            try rdpFileContents(ip: target.ip, name: target.vmName).write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
