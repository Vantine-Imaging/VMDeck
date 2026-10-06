import Foundation
import Observation

/// Live VM state for one host.
@MainActor
@Observable
final class VMStore {
    let host: Host

    private(set) var vms: [VirtualMachine] = []
    private(set) var hostStats: HostStats?
    /// Bundle sizes from `du`, fetched on demand for the stats panel.
    private(set) var diskUsage: [VirtualMachine.ID: Int64] = [:]
    private(set) var hasLoaded = false
    /// Set when the host itself can't be queried (ssh failed, vmrun missing).
    private(set) var hostError: String?
    /// Something in progress for a VM, started here or seen on the host.
    struct Activity: Equatable {
        var label: String
        var since: Date
        /// A clean shutdown is waiting on the guest; Force Stop can cut it short.
        var canForceStop: Bool
    }

    private struct InFlight {
        var token = UUID()
        var action: VMAction
        var since = Date.now
    }

    /// Actions this window started, per VM.
    private var inFlight: [VirtualMachine.ID: InFlight] = [:]
    var busy: Set<VirtualMachine.ID> { Set(inFlight.keys) }
    /// Last action error per VM, shown on its row until the next action.
    private(set) var rowErrors: [VirtualMachine.ID: String] = [:]
    /// VMs whose soft stop failed; they get a Force Stop button.
    private(set) var softStopFailed: Set<VirtualMachine.ID> = []

    @ObservationIgnored private let vmrun: VMRun
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshQueued = false
    /// Every .vmx seen this session. Passed back to discovery so a VM that
    /// was only found because it was running (stored somewhere VMDeck
    /// doesn't scan, and missing from Fusion's library) stays listed after
    /// it stops. Paths whose file is gone drop out on the host side.
    @ObservationIgnored private var seenPaths: [String] = []

    static let pollInterval: Duration = .seconds(5)

    /// `vmrun` overrides the host's own, for tests that need a custom runner.
    init(host: Host, vmrun: VMRun? = nil) {
        self.host = host
        self.vmrun = vmrun ?? host.vmrun
    }

    /// Refreshes until cancelled. Driven by the detail view's .task, so polling
    /// stops when the host isn't on screen.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func refresh() async {
        // An action finishing mid-refresh queues one more pass, so its result
        // shows up now rather than on the next poll.
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            await refreshOnce()
        } while refreshQueued
    }

    private func refreshOnce() async {
        do {
            let result = try await Discovery(vmrun: vmrun).discover(extraPaths: host.extraVMXPaths + seenPaths)
            let found = result.vms
            seenPaths = found.map(\.vmxPath)
            vms = found.map { d in
                var vm = VirtualMachine(vmxPath: d.vmxPath, displayName: d.displayName, powerState: d.powerState,
                                        config: d.config, process: d.process, volume: d.volume, pending: d.pending,
                                        autoStart: d.autoStart, restartSchedule: d.restartSchedule)
                guard d.powerState == .running else { return vm }
                vm.tools = d.tools
                (vm.ipAddress, vm.ipSource) = Self.chooseIP(guestIP: d.guestIP, macs: d.config.macAddresses,
                                                            neighbors: result.neighbors)
                return vm
            }
            hostStats = result.host
            let running = Set(vms.filter { $0.powerState == .running }.map(\.id))
            softStopFailed.formIntersection(running)
            hostError = nil
        } catch {
            hostError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// VMware Tools' answer when there is one; otherwise the first NIC whose
    /// MAC the host has seen on the network.
    nonisolated static func chooseIP(guestIP: String?, macs: [String],
                                     neighbors: [String: String]) -> (String?, VirtualMachine.IPSource?) {
        if let ip = guestIP { return (ip, .tools) }
        if let ip = macs.lazy.compactMap({ neighbors[$0] }).first { return (ip, .network) }
        return (nil, nil)
    }

    /// Loads the bundle size once per VM; the stats panel asks when shown.
    func loadDiskUsage(for vm: VirtualMachine) async {
        guard diskUsage[vm.id] == nil else { return }
        if let bytes = try? await vmrun.diskUsage(vm.id) {
            diskUsage[vm.id] = bytes
        }
    }

    /// What's in progress for `vm`, if anything: this window's own action
    /// first, else a vmrun command already running on the host (for example
    /// from before VMDeck was relaunched).
    func activity(for vm: VirtualMachine) -> Activity? {
        if let local = inFlight[vm.id] {
            return Activity(label: Self.progressLabel(local.action), since: local.since,
                            canForceStop: local.action == .stop)
        }
        if let pending = vm.pending {
            let action: VMAction = switch pending.kind {
            case .start: .start
            case .stop: pending.hard ? .forceStop : .stop
            case .suspend: .suspend
            case .reset: .reset
            }
            return Activity(label: Self.progressLabel(action), since: pending.startedAt,
                            canForceStop: action == .stop)
        }
        return nil
    }

    static func progressLabel(_ action: VMAction) -> String {
        switch action {
        case .start: "Starting"
        case .stop: "Shutting down"
        case .forceStop: "Powering off"
        case .suspend: "Suspending"
        case .reset: "Restarting"
        case .apply: "Applying changes"
        }
    }

    func perform(_ action: VMAction, on vm: VirtualMachine) async {
        let id = vm.id
        // Only Force Stop may overlap: it's how a stuck clean shutdown is cut short.
        if let current = activity(for: vm), !(action == .forceStop && current.canForceStop) { return }
        let entry = InFlight(action: action)
        inFlight[id] = entry
        rowErrors[id] = nil
        var failure: String?
        do {
            switch action {
            case .start: try await vmrun.start(id)
            case .stop: try await vmrun.stop(id, hard: false)
            case .forceStop: try await vmrun.stop(id, hard: true)
            case .suspend: try await vmrun.suspend(id)
            case .reset: try await vmrun.reset(id)
            case .apply: break
            }
            if action == .stop || action == .forceStop {
                softStopFailed.remove(id)
            }
        } catch VMRunError.vmrun(let message)
                    where (action == .stop || action == .forceStop) && message.contains("is not powered on") {
            // Already off, for example because a Force Stop beat this clean
            // shutdown to it. That's the outcome that was asked for.
        } catch {
            failure = error.localizedDescription
        }
        if inFlight[id]?.token == entry.token {
            inFlight[id] = nil
        }
        if let failure {
            rowErrors[id] = failure
            if action == .stop { softStopFailed.insert(id) }
        }
        await refresh()
    }

    // MARK: - Auto-start

    func autoStartStatus() async throws -> AutoStartStatus {
        try await AutoStartManager(vmrun: vmrun).status()
    }

    func installAutoStart(_ config: AutoStartConfig) async throws {
        try await AutoStartManager(vmrun: vmrun).install(config)
        await refresh()
    }

    func runAutoStartNow() async throws {
        try await AutoStartManager(vmrun: vmrun).runNow()
    }

    // MARK: - Scheduled restarts

    /// Auto-start and schedules together, one round trip.
    func automationStatus() async throws -> AutomationStatus {
        try await AutomationManager(vmrun: vmrun).status()
    }

    func scheduledRestartStatus() async throws -> ScheduledRestartStatus {
        try await ScheduledRestartManager(vmrun: vmrun).status()
    }

    func installScheduledRestarts(_ schedules: [String: RestartSchedule], shutdownWaitSeconds: Int) async throws {
        try await ScheduledRestartManager(vmrun: vmrun).install(schedules, shutdownWaitSeconds: shutdownWaitSeconds)
        await refresh()
    }

    func restartNow(_ vm: VirtualMachine) async throws {
        try await ScheduledRestartManager(vmrun: vmrun).restartNow(vm.id)
    }

    // MARK: - History

    func history(of vm: VirtualMachine) async throws -> VMHistory {
        try await VMHistoryManager(vmrun: vmrun).history(for: vm.id)
    }

    // MARK: - Usage history

    func usage(for vm: VirtualMachine?, range: UsageRange) async throws -> UsageSeries {
        try await UsageRecorderManager(vmrun: vmrun).series(for: vm?.id, range: range)
    }

    func setUsageRecording(_ on: Bool) async throws {
        try await UsageRecorderManager(vmrun: vmrun).setRecording(on)
    }

    // MARK: - Resources

    func inspectResources(of vm: VirtualMachine) async throws -> VMResources {
        try await ResourceEditor(vmrun: vmrun).inspect(vm.id)
    }

    func applyResources(_ change: ResourceChange, to vm: VirtualMachine) async throws -> [String] {
        let entry = InFlight(action: .apply)
        inFlight[vm.id] = entry
        defer { if inFlight[vm.id]?.token == entry.token { inFlight[vm.id] = nil } }
        let done = try await ResourceEditor(vmrun: vmrun).apply(change, to: vm.id)
        diskUsage[vm.id] = nil
        await refresh()
        return done
    }

    func actions(for vm: VirtualMachine) -> [VMAction] {
        switch vm.powerState {
        case .stopped, .suspended:
            return [.start]
        case .running:
            var actions: [VMAction] = [.stop, .suspend, .reset]
            if softStopFailed.contains(vm.id) {
                actions.insert(.forceStop, at: 1)
            }
            return actions
        }
    }
}
