import SwiftUI

/// Everything a host does on its own, at a glance: each VM's automation,
/// the host-wide timings, and the agents' state. Per-VM settings are edited
/// in AutomationSheet; this sheet owns the timings.
struct AutomationOverviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: VMStore

    @State private var status: AutomationStatus?
    @State private var loadError: String?
    @State private var waitMinutes = 10
    @State private var stagger = 15
    @State private var shutdownWaitMinutes = 10
    @State private var working = false
    @State private var message: String?
    @State private var showLog = false
    @State private var editing: VirtualMachine?

    private var host: Host { store.host }

    private var changed: Bool {
        guard let status else { return false }
        return waitMinutes * 60 != status.autoStart.config.waitSeconds
            || stagger != status.autoStart.config.staggerSeconds
            || shutdownWaitMinutes * 60 != status.restarts.shutdownWaitSeconds
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Automation on \(host.name)").font(.headline)
                    Spacer()
                    HelpButton(topic: HelpTopic.automation)
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
        .frame(width: 600)
        .frame(minHeight: 460, maxHeight: 880)
        .disabled(working)
        .task { await load() }
        .sheet(item: $editing) { vm in
            AutomationSheet(vm: vm, store: store)
        }
        // Pick up whatever the per-VM sheet saved.
        .onChange(of: editing) { _, now in if now == nil { Task { await load() } } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Button("Save Timing") { Task { await save() } }
                        .disabled(!changed)
                }
            }
        }
        .sheet(isPresented: $showLog) {
            LogSheet(title: "Automation logs on \(host.name)",
                     text: "Auto-start:\n\(status?.autoStart.recentLog ?? "")\n\nScheduled restarts:\n\(status?.restarts.recentLog ?? "")")
        }
    }

    @ViewBuilder
    private func content(_ status: AutomationStatus) -> some View {
        if status.autoStart.autoLoginUser == nil, !status.autoStart.config.isEmpty || !status.restarts.schedules.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Automatic login is off on \(host.name).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Automation runs in the logged-in user's session. After a reboot, nothing starts or restarts until someone logs in at that Mac. To make reboots hands-off, turn on automatic login there: System Settings > Users & Groups > Automatic login. (Not available while FileVault is on.)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            if store.vms.isEmpty {
                Text("No VMs found on this host yet.").foregroundStyle(.secondary)
            }
            ForEach(store.vms) { vm in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.displayName)
                        Text(status.summary(for: vm.id))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editing = vm }
                        .help("Change what \(vm.displayName) does on its own")
                }
            }
            // Listed on the host but not visible right now (an unmounted
            // volume, say). Still shown so they aren't forgotten.
            let missing = (status.autoStart.config.vmxPaths + status.restarts.schedules.keys)
                .filter { path in !store.vms.contains { $0.id == path } }
            ForEach(Array(Set(missing)).sorted(), id: \.self) { path in
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                    Text("Not found right now: \(path)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(status.summary(for: path)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Virtual Machines")
        } footer: {
            Text("Edit also opens from the stats panel. VMs start at login in the order shown, one at a time.")
        }

        Section {
            Stepper(value: $waitMinutes, in: 1...120) {
                LabeledContent("Wait for volumes", value: "up to \(waitMinutes) min")
            }
            Stepper(value: $stagger, in: 0...300, step: 5) {
                LabeledContent("Pause between starts", value: "\(stagger) s")
            }
            Stepper(value: $shutdownWaitMinutes, in: 1...60) {
                LabeledContent("Shutdown before power off", value: "up to \(shutdownWaitMinutes) min")
            }
        } header: {
            Text("Timing")
        } footer: {
            Text("An external RAID can mount minutes after login; each VM waits up to this long for its files before being skipped. A scheduled restart that has to shut the guest down waits this long before powering it off.")
        }

        Section {
            LabeledContent("Login agent") {
                Text(status.autoStart.installed
                     ? (status.autoStart.loaded ? "Installed and loaded" : "Installed, loads at next login")
                     : "Not installed")
            }
            let enabled = status.restarts.schedules.values.filter(\.enabled).count
            LabeledContent("Schedule agents", value: enabled == 0 ? "None"
                           : "\(status.restarts.loaded.count) of \(enabled) loaded")
            if let user = status.autoStart.consoleUser {
                LabeledContent("Logged in at screen", value: user)
            }
            LabeledContent("Automatic login", value: status.autoStart.autoLoginUser ?? "Off")
            HStack {
                Button("Run Auto-Start Now") { Task { await runNow() } }
                    .disabled(!status.autoStart.installed || changed)
                    .help("Start the login VMs now, the same way login would")
                Button("Show Log") { showLog = true }
                    .disabled(status.autoStart.recentLog.isEmpty && status.restarts.recentLog.isEmpty)
                Button("Refresh") { Task { await load() } }
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Files on the host: ~/Library/LaunchAgents/\(AutoStartManager.label).plist and \(ScheduledRestartManager.labelPrefix)<id>.plist, scripts and lists in ~/Library/Application Support/VMDeck/, logs in ~/Library/Logs/VMDeck/.")
        }
    }

    private func load() async {
        do {
            let s = try await store.automationStatus()
            status = s
            waitMinutes = max(1, s.autoStart.config.waitSeconds / 60)
            stagger = s.autoStart.config.staggerSeconds
            shutdownWaitMinutes = max(1, s.restarts.shutdownWaitSeconds / 60)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        guard let status else { return }
        working = true
        message = nil
        do {
            var config = status.autoStart.config
            config.waitSeconds = waitMinutes * 60
            config.staggerSeconds = stagger
            if config != status.autoStart.config, !config.isEmpty {
                try await store.installAutoStart(config)
            }
            if shutdownWaitMinutes * 60 != status.restarts.shutdownWaitSeconds, !status.restarts.schedules.isEmpty {
                try await store.installScheduledRestarts(status.restarts.schedules, shutdownWaitSeconds: shutdownWaitMinutes * 60)
            }
            await load()
            message = (status.autoStart.config.isEmpty && status.restarts.schedules.isEmpty)
                ? "Nothing is automated yet; timings apply once a VM is."
                : "Timing saved."
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
            message = "Running. Stopped VMs on the login list are starting; the log shows progress."
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
