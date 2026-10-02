import Foundation

enum PowerState: String, Sendable {
    case running, suspended, stopped

    var label: String {
        switch self {
        case .running: "Running"
        case .suspended: "Suspended"
        case .stopped: "Stopped"
        }
    }
}

/// What the host knows about VMware Tools in a running guest.
enum ToolsState: String, Sendable {
    /// Tools is publishing guest info (or vmrun says running).
    case running
    /// vmrun sees Tools on disk but no live handshake, and nothing published.
    case installed
    case notInstalled
    case unknown

    var label: String {
        switch self {
        case .running: "Running"
        case .installed: "Installed, not responding"
        case .notInstalled: "Not installed"
        case .unknown: "Unknown"
        }
    }

    init(vmrunWord: String) {
        switch vmrunWord.lowercased() {
        case "running": self = .running
        case "installed": self = .installed
        case "notinstalled", "not installed": self = .notInstalled
        default: self = .unknown
        }
    }
}

struct VirtualMachine: Identifiable, Equatable, Sendable {
    enum IPSource: Equatable, Sendable {
        /// Reported by VMware Tools in the guest.
        case tools
        /// Matched by MAC address in the host's ARP table or Fusion's DHCP
        /// leases, because Tools couldn't report one.
        case network
    }

    /// Canonical path to the .vmx on its host; unique per host.
    let vmxPath: String
    var displayName: String
    var powerState: PowerState
    var ipAddress: String?
    var ipSource: IPSource?
    var tools: ToolsState?
    var config = VMConfig()
    var process: VMProcessStats?
    var volume: VolumeStats?
    var pending: PendingOperation?
    /// Listed in the host's auto-start list.
    var autoStart = false
    /// The host's saved restart schedule for this VM, enabled or not.
    var restartSchedule: RestartSchedule?

    var id: String { vmxPath }
}

enum VMAction: String, Identifiable, Sendable {
    case start, stop, forceStop, suspend, reset
    /// Resource edits; only used to mark the VM busy.
    case apply

    var id: String { rawValue }

    /// Fusion's own words: Shut Down asks the guest, Power Off cuts power.
    var label: String {
        switch self {
        case .start: "Start"
        case .stop: "Shut Down"
        case .forceStop: "Power Off"
        case .suspend: "Suspend"
        case .reset: "Restart"
        case .apply: "Apply"
        }
    }

    /// The label for this action on a VM in `state`: starting a suspended
    /// VM resumes it.
    func label(for state: PowerState) -> String {
        self == .start && state == .suspended ? "Resume" : label
    }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .forceStop: "power"
        case .suspend: "pause.fill"
        case .reset: "arrow.counterclockwise"
        case .apply: "slider.horizontal.3"
        }
    }

    var help: String {
        switch self {
        case .start: "Start without a window (headless). A suspended VM resumes where it left off."
        case .stop: "Ask the guest OS to shut down cleanly. Needs VMware Tools in the guest, and waits until it has powered off."
        case .forceStop: "Cut power to the VM immediately, like pulling the plug"
        case .suspend: "Save the VM's memory to disk and pause it"
        case .reset: "Restart the guest. Falls back to a hard reset if VMware Tools can't restart it cleanly."
        case .apply: ""
        }
    }

    /// Actions that can lose unsaved guest state get a confirmation dialog.
    var needsConfirmation: Bool { self == .forceStop || self == .reset }
}
