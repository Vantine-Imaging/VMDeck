import SwiftUI

struct PendingAction: Identifiable {
    let action: VMAction
    let vm: VirtualMachine
    var id: String { vm.id + action.rawValue }
}

struct VMTable: View {
    let store: VMStore
    @Binding var selection: VirtualMachine.ID?
    let onEdit: (VirtualMachine) -> Void
    /// Hidden while the stats inspector is open: it shows the same numbers,
    /// and the room goes to the Actions column.
    var showUsage = true
    @State var pending: PendingAction?

    var body: some View {
        Table(store.vms, selection: $selection) {
            TableColumn("Name") { vm in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(vm.displayName)
                        if vm.autoStart {
                            Image(systemName: "bolt.badge.clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Starts at login on the host")
                        }
                        if let s = vm.restartSchedule, s.enabled {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("\(s.verb) \(s.sentenceLabel) (host's local time)")
                        }
                    }
                    Text(vm.vmxPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(vm.vmxPath)
                    if let error = store.rowErrors[vm.id] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 150, ideal: 300)

            TableColumn("State") { vm in
                StateBadge(state: vm.powerState)
            }
            .width(min: 88, ideal: 100)

            TableColumn("IP Address") { vm in
                HStack(spacing: 4) {
                    Text(vm.ipAddress ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(vm.ipAddress == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                    if vm.ipSource == .network {
                        Image(systemName: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(ipHelp(vm))
            }
            .width(min: 105, ideal: 140)

            // Conditional columns rebuild the table, which is fine here: this
            // only changes when the stats inspector is toggled, never on a click.
            if showUsage {
            TableColumn("Usage") { vm in
                if let p = vm.process {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CPU \(Format.percent(p.cpuShare(vcpus: vm.config.vcpus)))").monospacedDigit()
                        Text(Format.bytes(p.residentBytes)).font(.caption).foregroundStyle(.secondary)
                    }
                    .help("CPU use across this VM's \(vm.config.vcpus ?? 1) vCPUs (\(Format.percent(p.cpuPercent)) of one host core), and host memory used")
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 95)
            }

            TableColumn("Actions") { vm in
                // Full labels when they fit, icons (with tooltips) when the
                // column is narrow, e.g. with the stats inspector open.
                // Never truncated either way.
                ViewThatFits(in: .horizontal) {
                    actionRow(vm, iconsOnly: false)
                    actionRow(vm, iconsOnly: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 110, ideal: 380)
        }
        .confirmationDialog(
            pending.map { "\($0.action.label) \($0.vm.displayName)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { pending in
            Button(pending.action.label, role: .destructive) {
                Task { await store.perform(pending.action, on: pending.vm) }
            }
        } message: { pending in
            Text(pending.action == .reset
                 ? "VMDeck asks the guest to restart. If VMware Tools can't do that, the VM is reset immediately and unsaved work in it may be lost."
                 : "This cuts power to the VM, like pulling the plug. Unsaved work in the VM will be lost.")
        }
    }
}

extension VMTable {
    @ViewBuilder
    func actionRow(_ vm: VirtualMachine, iconsOnly: Bool) -> some View {
        HStack(spacing: 6) {
            if let activity = store.activity(for: vm) {
                ProgressView().controlSize(.small)
                if !iconsOnly { Text(activity.label).fixedSize() }
                Text(activity.since, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(activity.label)
                if activity.canForceStop {
                    actionButton(.forceStop, title: VMAction.forceStop.label, iconsOnly: iconsOnly,
                                 help: "Cut power to the VM instead of waiting for the guest to shut down") {
                        pending = PendingAction(action: .forceStop, vm: vm)
                    }
                }
            } else {
                ForEach(store.actions(for: vm)) { action in
                    actionButton(action, title: action.label(for: vm.powerState), iconsOnly: iconsOnly,
                                 help: action.help) {
                        if action.needsConfirmation {
                            pending = PendingAction(action: action, vm: vm)
                        } else {
                            Task { await store.perform(action, on: vm) }
                        }
                    }
                }
                if let target = RemoteDesktop.target(for: vm) {
                    Button { try? RemoteDesktop.open(target) } label: {
                        buttonLabel("Connect", systemImage: "rectangle.inset.filled.and.person.filled", iconsOnly: iconsOnly)
                    }
                    .disabled(target.handler == nil)
                    .help(target.help)
                    .fixedSize()
                }
                if vm.powerState == .stopped {
                    Button { onEdit(vm) } label: {
                        buttonLabel("Edit", systemImage: "slider.horizontal.3", iconsOnly: iconsOnly)
                    }
                    .help("Change vCPUs, memory, and disk sizes")
                    .fixedSize()
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func actionButton(_ action: VMAction, title: String, iconsOnly: Bool, help: String,
                              perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            buttonLabel(title, systemImage: action.systemImage, iconsOnly: iconsOnly)
        }
        .tint(action == .forceStop ? .red : nil)
        .help(iconsOnly ? "\(title): \(help)" : help)
        .fixedSize()
    }

    @ViewBuilder
    private func buttonLabel(_ title: String, systemImage: String, iconsOnly: Bool) -> some View {
        if iconsOnly {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}

private func ipHelp(_ vm: VirtualMachine) -> String {
    switch (vm.ipAddress, vm.ipSource, vm.powerState) {
    case (_?, .network?, _):
        "Found by MAC address in the host's ARP table or Fusion's DHCP leases. VMware Tools in the guest isn't reporting an address."
    case (_?, _, _):
        "Reported by VMware Tools in the guest"
    case (nil, _, .running):
        switch vm.tools {
        case .installed?, .notInstalled?:
            "VMware Tools isn't reporting in the guest, and the host hasn't seen its MAC address on the network yet."
        default:
            "No address reported yet"
        }
    default:
        "The VM isn't running"
    }
}

struct StateBadge: View {
    let state: PowerState

    private var color: Color {
        switch state {
        case .running: .green
        case .suspended: .orange
        case .stopped: .secondary
        }
    }

    var body: some View {
        Label {
            Text(state.label)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }
}
