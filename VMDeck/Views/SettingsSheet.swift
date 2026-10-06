import SwiftUI

/// Queue .vmx settings for a VM. They're written to the VM at its next
/// scheduled power cycle, or right away with Apply Now while it's off.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let vm: VirtualMachine
    let store: VMStore

    @State private var status: PendingSettingsStatus?
    @State private var loadError: String?
    @State private var rows: [PendingSetting] = []
    @State private var working = false
    @State private var message: String?
    @State private var confirmingApply = false

    private var host: Host { store.host }
    private var valid: Bool { rows.allSatisfy { $0.isValid && !$0.value.isEmpty } && Set(rows.map(\.key)).count == rows.count }
    private var changed: Bool { status.map { $0.pending.map(\.line) != rows.map(\.line) } ?? false }
    private var canApplyNow: Bool { vm.powerState == .stopped && !(status?.pending.isEmpty ?? true) && !changed }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Settings: \(vm.displayName)").font(.headline)
                    Spacer()
                    HelpButton(topic: HelpTopic.settings)
                }
            }
            if let status {
                content(status)
            } else if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(vm.displayName)'s settings on \(host.name)").foregroundStyle(.secondary)
                }
            }
            if let message {
                Section {
                    Label(message, systemImage: message.hasPrefix("Couldn't") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(message.hasPrefix("Couldn't") ? .red : .green)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .frame(minHeight: 420, maxHeight: 760)
        .disabled(working)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Button("Save") { Task { await save() } }
                        .disabled(!changed || !valid)
                        .help(valid ? "Queue these settings on \(host.name)" : "Each row needs a valid key and a value, and keys can't repeat")
                }
            }
        }
        .confirmationDialog("Apply the queued settings to \(vm.displayName) now?", isPresented: $confirmingApply) {
            Button("Apply Now") { Task { await applyNow() } }
        } message: {
            Text("The .vmx is backed up and rewritten while the VM is off. The changes take effect when it next starts.")
        }
    }

    @ViewBuilder
    private func content(_ status: PendingSettingsStatus) -> some View {
        Section {
            if rows.isEmpty {
                Text("Nothing queued. Add a setting below.").foregroundStyle(.secondary)
            }
            ForEach($rows) { $row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            TextField("key", text: $row.key, prompt: Text("numvcpus"))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 220)
                            Menu {
                                ForEach(PendingSetting.presets, id: \.key) { preset in
                                    Button(preset.key) { row.key = preset.key }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Common settings")
                        }
                        if !row.key.isEmpty, !row.isValid {
                            Text("Letters, digits, dots, colons, dashes and underscores only.").font(.caption).foregroundStyle(.red)
                        } else if let hint = PendingSetting.presets.first(where: { $0.key == row.key })?.hint {
                            Text(hint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TextField("value", text: $row.value, prompt: Text("value"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 140)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("now").font(.caption2).foregroundStyle(.tertiary)
                        Text(status.current[row.key] ?? "not set")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 110, alignment: .leading)
                    Spacer(minLength: 0)
                    Button("Remove", systemImage: "minus.circle") { rows.removeAll { $0.id == row.id } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove this row")
                }
            }
            Button("Add Setting", systemImage: "plus") { rows.append(PendingSetting(key: "", value: "")) }
        } header: {
            Text("Queued for the Next Power Cycle")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Each row becomes a `key = \"value\"` line in \(vm.displayName)'s .vmx, replacing the key if it exists. VMDeck can't edit the file while the VM runs, because Fusion rewrites it from memory when the VM powers off and would undo the change. Queued settings wait in \(URL(fileURLWithPath: vm.vmxPath).lastPathComponent).vmdeck-pending next to it.")
                if !status.vmxWritable {
                    Label("The .vmx isn't writable by \(host.name)'s user, so applying would fail.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }

        Section {
            LabeledContent("Applied by") {
                Text(appliedBy)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Button("Apply Now") { confirmingApply = true }
                    .disabled(!canApplyNow)
                    .help(canApplyNow ? "Write the queued settings into the .vmx now" : "Shut the VM down and save first")
                Text(vm.powerState == .stopped ? "The VM is shut down, so this can happen right away."
                     : vm.powerState == .suspended ? "The VM is suspended. Hardware can't change on a resume; it needs a shutdown and start."
                     : "While the VM runs, the next scheduled power cycle applies them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("When It Happens")
        }
    }

    private var appliedBy: String {
        if let s = vm.restartSchedule, s.enabled, s.method == .cycle {
            return "The scheduled power cycle, \(s.sentenceLabel), or Apply Now while shut down"
        }
        if let s = vm.restartSchedule, s.enabled {
            return "Apply Now while shut down. The schedule's method (\(s.method.label.lowercased())) doesn't apply settings; switch it to Power cycle in Automation to have it do so."
        }
        return "Apply Now while shut down, or a scheduled power cycle (set one up in Automation)."
    }

    private func load() async {
        do {
            let s = try await store.pendingSettings(of: vm)
            status = s
            rows = s.pending
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        working = true
        message = nil
        do {
            try await store.savePendingSettings(rows, for: vm)
            message = rows.isEmpty ? "Queue cleared." : "Queued \(rows.count) setting\(rows.count == 1 ? "" : "s") for \(vm.displayName)."
            await load()
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
        working = false
    }

    private func applyNow() async {
        working = true
        message = nil
        do {
            let done = try await store.applyPendingSettingsNow(for: vm)
            message = "Applied: \(done.joined(separator: ", ")). A backup is next to the .vmx."
            await load()
        } catch {
            message = "Couldn't apply: \(error.localizedDescription)"
        }
        working = false
    }
}
