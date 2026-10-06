import SwiftUI

/// What one VM does on its own: start at login, restart on a schedule.
struct AutomationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let vm: VirtualMachine
    let store: VMStore

    @State private var status: AutomationStatus?
    @State private var loadError: String?
    @State private var startAtLogin = false
    @State private var scheduled = false
    @State private var method: RestartSchedule.Method = .reboot
    @State private var time = Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: .now) ?? .now
    @State private var weekdays: Set<Int> = Set(0...6)
    @State private var working = false
    @State private var message: String?
    @State private var confirmingRestart = false

    private var host: Host { store.host }

    private var draftSchedule: RestartSchedule {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return RestartSchedule(hour: parts.hour ?? 0, minute: parts.minute ?? 0, weekdays: weekdays, enabled: scheduled, method: method)
    }

    private var savedSchedule: RestartSchedule? { status?.restarts.schedules[vm.id] }
    private var savedAtLogin: Bool { status?.autoStart.config.vmxPaths.contains(vm.id) ?? false }

    private var scheduleChanged: Bool {
        draftSchedule != (savedSchedule ?? RestartSchedule(enabled: false))
    }
    private var changed: Bool { status != nil && (startAtLogin != savedAtLogin || scheduleChanged) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Automation: \(vm.displayName)").font(.headline)
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
        .frame(width: 560)
        .frame(minHeight: 480, maxHeight: 880)
        .disabled(working)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Button("Save") { Task { await save() } }
                        .disabled(!changed || (scheduled && weekdays.isEmpty))
                }
            }
        }
        .confirmationDialog("Restart \(vm.displayName) now?", isPresented: $confirmingRestart) {
            Button("Restart", role: .destructive) { Task { await restartNow() } }
        } message: {
            Text(restartNowMessage)
        }
    }

    private var waitMinutes: Int { max(1, (status?.restarts.shutdownWaitSeconds ?? 600) / 60) }

    private var restartNowMessage: String {
        switch method {
        case .cycle: "VMDeck shuts the VM down, waiting up to \(waitMinutes) min before powering off, then starts it again. Unsaved work in the VM may be lost."
        case .suspend: "VMDeck suspends the VM and resumes it. The guest picks up where it was; it's unreachable for a minute or two."
        case .reboot: "The guest is asked to restart. If it can't, VMDeck shuts it down, waiting up to \(waitMinutes) min before powering off, then starts it again. Unsaved work in the VM may be lost."
        }
    }

    @ViewBuilder
    private func content(_ status: AutomationStatus) -> some View {
        Section {
            Toggle("Start at login", isOn: $startAtLogin)
            if startAtLogin, status.autoStart.autoLoginUser == nil {
                Label("Automatic login is off on \(host.name), so after a reboot nothing starts until someone logs in there. System Settings > Users & Groups > Automatic login.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Start at Login")
        } footer: {
            Text("Starts headless whenever \(host.name)'s user logs in, waiting up to \(max(1, status.autoStart.config.waitSeconds / 60)) min for its volume to mount. VMs start one at a time, \(status.autoStart.config.staggerSeconds) s apart. Those timings are host-wide; change them under Automation in the toolbar.")
        }

        Section {
            Toggle("Restart on a schedule", isOn: $scheduled)
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .disabled(!scheduled)
            VStack(alignment: .leading, spacing: 8) {
                Text("Days")
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { day in
                        Toggle(RestartSchedule.dayNames[day], isOn: Binding(
                            get: { weekdays.contains(day) },
                            set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } }))
                            .toggleStyle(.button)
                    }
                    Spacer()
                    Menu("Presets") {
                        Button("Every day") { weekdays = Set(0...6) }
                        Button("Weekdays") { weekdays = Set(1...5) }
                        Button("Weekends") { weekdays = [0, 6] }
                        Button("Sundays only") { weekdays = [0] }
                    }
                    .fixedSize()
                }
            }
            .disabled(!scheduled)
            Picker("Method", selection: $method) {
                ForEach(RestartSchedule.Method.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .disabled(!scheduled)
        } header: {
            Text("Scheduled Restart")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if scheduled, let next = draftSchedule.nextRun() {
                    Text("Next \(method.noun): \(next.formatted(date: .abbreviated, time: .shortened)), in \(host.name)'s local time.")
                } else if scheduled {
                    Text("Pick at least one day.")
                }
                switch method {
                case .cycle:
                    Text("The VM is shut down cleanly (up to \(waitMinutes) min, then powered off) and started again headless. That replaces the VM's process on the host, which frees memory it has accumulated, and applies settings queued for the next power-on. The guest boots, so a few minutes of downtime.")
                case .suspend:
                    Text("The VM is suspended and resumed. That also replaces the VM's process on the host, but the guest carries on where it was instead of booting, so no boot-time problems and only a minute or two unreachable. Settings changes don't apply on a resume.")
                case .reboot:
                    Text("The guest is asked to restart through VMware Tools, like choosing Restart inside it; the VM's process on the host keeps running. If the guest can't, the VM is shut down (up to \(waitMinutes) min, then powered off) and started again headless.")
                }
            }
        }

        Section {
            LabeledContent("Saved", value: status.summary(for: vm.id))
            if savedAtLogin {
                LabeledContent("Login agent", value: status.autoStart.loaded ? "Loaded on \(host.name)"
                               : "Installed, loads at next login")
            }
            if let saved = savedSchedule, saved.enabled {
                LabeledContent("Schedule agent", value: status.restarts.loaded.contains(ScheduledRestartManager.id(for: vm.id))
                               ? "Loaded on \(host.name)" : "Not loaded (loads at next login)")
            }
            HStack {
                Button("Restart Now") { confirmingRestart = true }
                    .disabled(vm.powerState != .running || changed || savedSchedule == nil)
                    .help(changed ? "Save first" : "Restart \(vm.displayName) now, the way a scheduled restart would")
                Text(vm.powerState != .running ? "The VM isn't running."
                     : savedSchedule == nil ? "Save a schedule first." : "Runs the scheduled steps immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let mine = (status.autoStart.recentLog + "\n" + status.restarts.recentLog)
                .split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("\(vm.displayName): ") || $0.contains(" \(vm.displayName): ") }
            if !mine.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(mine.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Status")
        }
    }

    private func load() async {
        do {
            let s = try await store.automationStatus()
            status = s
            startAtLogin = s.autoStart.config.vmxPaths.contains(vm.id)
            if let mine = s.restarts.schedules[vm.id] {
                scheduled = mine.enabled
                method = mine.method
                weekdays = mine.weekdays
                time = Calendar.current.date(bySettingHour: mine.hour, minute: mine.minute, second: 0, of: .now) ?? time
            } else {
                scheduled = false
            }
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
            if startAtLogin != savedAtLogin {
                var config = status.autoStart.config
                config.vmxPaths.removeAll { $0 == vm.id }
                if startAtLogin {
                    // Keep the list in table order; unknown paths sort last.
                    config.vmxPaths.append(vm.id)
                    let order = store.vms.map(\.id)
                    config.vmxPaths.sort { a, b in
                        let ia = order.firstIndex(of: a) ?? Int.max
                        let ib = order.firstIndex(of: b) ?? Int.max
                        return ia != ib ? ia < ib : a < b
                    }
                }
                try await store.installAutoStart(config)
            }
            if scheduleChanged {
                var all = status.restarts.schedules
                if scheduled || all[vm.id] != nil { all[vm.id] = draftSchedule }
                try await store.installScheduledRestarts(all, shutdownWaitSeconds: status.restarts.shutdownWaitSeconds)
            }
            await load()
            message = "Saved. \(vm.displayName): \(self.status?.summary(for: vm.id).lowercased() ?? "")."
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
        working = false
    }

    private func restartNow() async {
        working = true
        message = nil
        do {
            try await store.restartNow(vm)
            message = "Restarting \(vm.displayName). The log shows progress."
            try? await Task.sleep(for: .seconds(4))
            await load()
        } catch {
            message = "Couldn't restart: \(error.localizedDescription)"
        }
        working = false
    }
}
