import SwiftUI

/// Change a stopped VM's vCPUs, memory, and disk sizes.
struct EditResourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let vm: VirtualMachine
    let store: VMStore

    @State private var current: VMResources?
    @State private var loadError: String?
    @State private var vcpus = 1
    @State private var memoryMB = 1024
    /// Disk path → requested size in GB.
    @State private var diskGB: [String: Int] = [:]
    @State private var confirming = false
    @State private var applying = false
    @State private var applyError: String?

    private var maxCPUs: Int { max(store.hostStats?.cpuCount ?? 64, vcpus) }
    private var hostMemoryMB: Int { Int((store.hostStats?.memoryBytes ?? 0) / 1_048_576) }
    private var maxMemoryMB: Int { max(hostMemoryMB > 0 ? hostMemoryMB : 131_072, memoryMB) }

    /// Live state: the VM may have been started since the sheet opened.
    private var isStopped: Bool {
        store.vms.first { $0.id == vm.id }?.powerState == .stopped
    }

    private var change: ResourceChange? {
        current.map { ResourceChange.between($0, vcpus: vcpus, memoryMB: memoryMB,
                                             diskSizesMB: diskGB.mapValues { $0 * 1024 }) }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Edit \(vm.displayName)").font(.headline)
                    Spacer()
                    HelpButton(topic: HelpTopic.resources)
                }
            }
            if let current {
                warnings(current)
                cpuMemorySection
                disksSection(current)
                if let applyError {
                    Section {
                        Label(applyError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            } else if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(vm.displayName)'s configuration").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 420)
        .disabled(applying)
        .navigationTitle("Edit \(vm.displayName)")
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(applying)
            }
            ToolbarItem(placement: .confirmationAction) {
                HStack {
                    if applying { ProgressView().controlSize(.small) }
                    Button("Apply") { confirming = true }
                        .disabled(applying || !isStopped || change?.isEmpty != false)
                }
            }
        }
        .confirmationDialog("Apply changes to \(vm.displayName)?", isPresented: $confirming) {
            Button("Apply") { Task { await apply() } }
        } message: {
            Text(summary)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func warnings(_ current: VMResources) -> some View {
        if !isStopped {
            Section {
                Label("\(vm.displayName) isn't shut down. Shut it down to apply changes. A suspended VM has to be started and then shut down.",
                      systemImage: "power")
                    .foregroundStyle(.red)
            }
        }
        if current.fusionAppRunning || current.locked {
            Section {
                if current.fusionAppRunning {
                    Label("VMware Fusion is open on \(store.host.name). If this VM's window is open there, close it before applying, or Fusion may overwrite these changes.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if current.locked {
                    Label("The VM's folder has lock files, so something may still have it open. If it was shut down cleanly and Fusion doesn't have it open, it's safe to continue.",
                          systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var cpuMemorySection: some View {
        Section {
            Stepper(value: $vcpus, in: 1...maxCPUs) {
                LabeledContent("vCPUs", value: String(vcpus))
            }
            Stepper(value: $memoryMB, in: 256...maxMemoryMB, step: 1024) {
                LabeledContent("Memory", value: Format.bytes(Int64(memoryMB) * 1_048_576))
            }
            if hostMemoryMB > 0, memoryMB > hostMemoryMB * 3 / 4 {
                Label("That's over 75% of \(store.host.name)'s memory. Leave room for the host and other VMs.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Processors and Memory")
        } footer: {
            Text("\(store.host.name) has \(store.hostStats?.cpuCount ?? 0) cores and \(Format.bytes(Int64(hostMemoryMB) * 1_048_576)) of memory. VMDeck backs up the .vmx before changing it.")
        }
    }

    @ViewBuilder
    private func disksSection(_ current: VMResources) -> some View {
        Section {
            if current.disks.isEmpty {
                Text("No virtual disks found in the .vmx.").foregroundStyle(.secondary)
            }
            ForEach(current.disks) { disk in
                DiskRow(disk: disk, requestedGB: binding(for: disk))
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Disks can only grow. Afterwards, extend the partition inside the guest: in Windows, open Disk Management, right-click the drive, and choose Extend Volume. In macOS, use Disk Utility or diskutil apfs resizeContainer.")
        }
    }

    private func binding(for disk: VMDisk) -> Binding<Int> {
        Binding(
            get: { diskGB[disk.path] ?? disk.currentGB },
            set: { diskGB[disk.path] = max($0, disk.currentGB) })
    }

    private var summary: String {
        guard let change, let current else { return "" }
        var lines: [String] = []
        if let v = change.vcpus { lines.append("vCPUs: \(current.vcpus) → \(v)") }
        if let m = change.memoryMB {
            lines.append("Memory: \(Format.bytes(Int64(current.memoryMB) * 1_048_576)) → \(Format.bytes(Int64(m) * 1_048_576))")
        }
        for disk in current.disks {
            if let mb = change.diskSizesMB[disk.path] {
                lines.append("\(disk.fileName): \(disk.currentGB) GB → \(mb / 1024) GB")
            }
        }
        if change.diskSizesMB.keys.contains(where: { path in current.disks.first { $0.path == path }?.isPreallocated == true }) {
            lines.append("Growing a preallocated disk writes the new space out in full and can take a while.")
        }
        lines.append("Growing a disk can't be undone.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    private func load() async {
        do {
            let resources = try await store.inspectResources(of: vm)
            current = resources
            vcpus = resources.vcpus
            memoryMB = max(resources.memoryMB, 256)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply() async {
        guard let change else { return }
        applying = true
        applyError = nil
        do {
            _ = try await store.applyResources(change, to: vm)
            dismiss()
        } catch {
            applyError = error.localizedDescription
            // Some steps may have gone through; show what's there now.
            await load()
        }
        applying = false
    }
}

private struct DiskRow: View {
    let disk: VMDisk
    @Binding var requestedGB: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(disk.fileName, systemImage: "internaldrive")
                Spacer()
                Text(disk.device).font(.caption).foregroundStyle(.secondary)
            }
            if let reason = disk.cannotGrowReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Current size \(disk.currentGB) GB")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Size", value: $requestedGB, format: .number.grouping(.never))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("GB")
                    Stepper("Size", value: $requestedGB, in: disk.currentGB...16_384, step: 10)
                        .labelsHidden()
                }
                if disk.isPreallocated {
                    Text("Preallocated disk: growing it uses the full new size on the host's volume right away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
