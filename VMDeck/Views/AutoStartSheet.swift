import SwiftUI

/// Choose which of a host's VMs start on their own at login, and how long
/// the host waits for their volumes.
struct AutoStartSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: VMStore

    @State private var status: AutoStartStatus?
    @State private var loadError: String?
    @State private var selected: [String] = []
    @State private var waitMinutes = 10
    @State private var stagger = 15
    @State private var working = false
    @State private var message: String?
    @State private var showLog = false

    private var host: Host { store.host }
    private var vms: [VirtualMachine] { store.vms }

    private var draft: AutoStartConfig {
        AutoStartConfig(vmxPaths: selected, waitSeconds: waitMinutes * 60, staggerSeconds: stagger)
    }

    private var changed: Bool {
        guard let status else { return false }
        return draft != status.config || (status.installed && draft.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Auto-Start on \(host.name)").font(.headline)
                    Spacer()
                    HelpButton(topic: HelpTopic.autoStart)
                }
            }
            if let status {
                content(status)
            } else if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(host.name)").foregroundStyle(.secondary)
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
        .frame(width: 560)
        .frame(minHeight: 420, maxHeight: 700)
        .disabled(working)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Button("Run Now") { Task { await runNow() } }
                        .disabled(status?.installed != true || changed)
                        .help("Start the listed VMs now, the same way login would")
                    Button("Save") { Task { await save() } }
                        .disabled(!changed)
                }
            }
        }
        .sheet(isPresented: $showLog) {
            LogSheet(title: "Auto-start log on \(host.name)", text: status?.recentLog ?? "")
        }
    }

    @ViewBuilder
    private func content(_ status: AutoStartStatus) -> some View {
        if status.installed, status.consoleUser == nil {
            Section {
                Label("Nobody is logged in at \(host.name)'s screen, so the agent isn't running. It starts VMs when someone logs in.",
                      systemImage: "person.slash")
                    .foregroundStyle(.orange)
            }
        }
        if status.autoLoginUser == nil {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Automatic login is off on \(host.name).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Auto-start runs when a user logs in. After a reboot, nothing starts until someone logs in at that Mac. To make reboots hands-off, turn on automatic login there: System Settings > Users & Groups > Automatic login. (Not available while FileVault is on.)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            if vms.isEmpty {
                Text("No VMs found on this host yet.").foregroundStyle(.secondary)
            }
            ForEach(vms) { vm in
                Toggle(isOn: binding(for: vm.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.displayName)
                        Text(vm.vmxPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            // VMs in the saved list that discovery can't see right now (an
            // unmounted volume, say) still count; don't silently drop them.
            ForEach(status.config.vmxPaths.filter { path in !vms.contains { $0.id == path } }, id: \.self) { path in
                Toggle(isOn: binding(for: path)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                        Text("Not found right now: \(path)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        } header: {
            Text("Start at Login")
        } footer: {
            Text("VMs start headless in the order listed, one at a time. Fusion doesn't need to be open.")
        }

        Section {
            Stepper(value: $waitMinutes, in: 1...120) {
                LabeledContent("Wait for volumes", value: "up to \(waitMinutes) min")
            }
            Stepper(value: $stagger, in: 0...300, step: 5) {
                LabeledContent("Pause between starts", value: "\(stagger) s")
            }
        } header: {
            Text("Timing")
        } footer: {
            Text("An external RAID can mount minutes after login. Each VM waits up to this long for its files before being skipped. Skipped VMs are noted in the log.")
        }

        Section {
            LabeledContent("Agent") {
                Text(status.installed ? (status.loaded ? "Installed and loaded" : "Installed, loads at next login") : "Not installed")
            }
            if let user = status.consoleUser {
                LabeledContent("Logged in at screen", value: user)
            }
            LabeledContent("Automatic login", value: status.autoLoginUser ?? "Off")
            HStack {
                Button("Show Log") { showLog = true }
                    .disabled(status.recentLog.isEmpty)
                Button("Refresh") { Task { await load() } }
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Files on the host: ~/Library/LaunchAgents/\(AutoStartManager.label).plist, ~/Library/Application Support/VMDeck/autostart.sh and .list, log in ~/Library/Logs/VMDeck/.")
        }
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(path) },
            set: { on in
                if on {
                    if !selected.contains(path) { selected.append(path) }
                } else {
                    selected.removeAll { $0 == path }
                }
                // Keep start order = table order for discovered VMs.
                let order = vms.map(\.id)
                selected.sort { a, b in
                    let ia = order.firstIndex(of: a) ?? Int.max
                    let ib = order.firstIndex(of: b) ?? Int.max
                    return ia != ib ? ia < ib : a < b
                }
            })
    }

    private func load() async {
        do {
            let s = try await store.autoStartStatus()
            status = s
            selected = s.config.vmxPaths
            waitMinutes = max(1, s.config.waitSeconds / 60)
            stagger = s.config.staggerSeconds
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        working = true
        message = nil
        do {
            try await store.installAutoStart(draft)
            message = draft.isEmpty ? "Auto-start removed from \(host.name)." : "Saved. \(draft.vmxPaths.count) VM\(draft.vmxPaths.count == 1 ? "" : "s") will start at login."
            await load()
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
        working = false
    }

    private func runNow() async {
        working = true
        message = nil
        do {
            try await store.runAutoStartNow()
            message = "Running. Stopped VMs on the list are starting; the log shows progress."
            try? await Task.sleep(for: .seconds(3))
            await load()
        } catch {
            message = "Couldn't run: \(error.localizedDescription)"
        }
        working = false
    }
}

struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView {
                Text(text.isEmpty ? "No log yet." : text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 640)
    }
}
