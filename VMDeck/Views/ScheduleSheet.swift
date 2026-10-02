import SwiftUI

/// Set up a recurring restart for one VM.
struct ScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let vm: VirtualMachine
    let store: VMStore

    @State private var status: ScheduledRestartStatus?
    @State private var loadError: String?
    @State private var enabled = false
    @State private var time = Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: .now) ?? .now
    @State private var weekdays: Set<Int> = Set(0...6)
    @State private var shutdownWaitMinutes = 10
    @State private var working = false
    @State private var message: String?
    @State private var confirmingRestart = false

    private var draft: RestartSchedule {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return RestartSchedule(hour: parts.hour ?? 0, minute: parts.minute ?? 0, weekdays: weekdays, enabled: enabled)
    }

    private var saved: RestartSchedule? { status?.schedules[vm.id] }

    private var changed: Bool {
        guard let status else { return false }
        let current = saved ?? RestartSchedule(enabled: false)
        return draft != current || shutdownWaitMinutes * 60 != status.shutdownWaitSeconds
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Scheduled Restart: \(vm.displayName)").font(.headline)
                    Spacer()
                    HelpButton(topic: HelpTopic.schedule)
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
                    Text("Checking \(store.host.name)").foregroundStyle(.secondary)
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
        .frame(minHeight: 440, maxHeight: 720)
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
                        .disabled(!changed)
                }
            }
        }
        .confirmationDialog("Restart \(vm.displayName) now?", isPresented: $confirmingRestart) {
            Button("Restart", role: .destructive) { Task { await restartNow() } }
        } message: {
            Text("The guest is asked to restart. If it can't, VMDeck shuts it down, waiting up to \(shutdownWaitMinutes) min before powering off, then starts it again. Unsaved work in the VM may be lost.")
        }
    }

    @ViewBuilder
    private func content(_ status: ScheduledRestartStatus) -> some View {
        Section {
            Toggle("Restart on a schedule", isOn: $enabled)
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .disabled(!enabled)
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
            .disabled(!enabled)
        } header: {
            Text("Schedule")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if enabled, let next = draft.nextRun() {
                    Text("Next restart: \(next.formatted(date: .abbreviated, time: .shortened)), in \(store.host.name)'s local time.")
                } else if enabled {
                    Text("Pick at least one day.")
                }
                Text("At that time the guest is asked to restart through VMware Tools. If it can't, the VM is shut down and started again headless.")
            }
        }

        Section {
            Stepper(value: $shutdownWaitMinutes, in: 1...60) {
                LabeledContent("Give the guest up to", value: "\(shutdownWaitMinutes) min to shut down")
            }
        } header: {
            Text("If a Shutdown Is Needed")
        } footer: {
            Text("Applies to every scheduled restart on \(store.host.name). After this long, the VM is powered off and started again.")
        }

        Section {
            LabeledContent("Saved schedule", value: saved?.label ?? "None")
            HStack {
                Button("Restart Now") { confirmingRestart = true }
                    .disabled(vm.powerState != .running || changed || saved == nil)
                    .help(changed ? "Save first" : "Restart \(vm.displayName) now, the way the schedule would")
                Text(vm.powerState == .running ? "Runs the scheduled steps immediately." : "The VM isn't running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let saved, saved.enabled {
                LabeledContent("Agent", value: status.loaded.contains(ScheduledRestartManager.id(for: vm.id))
                               ? "Loaded on \(store.host.name)" : "Not loaded (loads at next login)")
            }
            let mine = status.recentLog.split(whereSeparator: \.isNewline).filter { $0.contains(" \(vm.displayName): ") }
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
            let s = try await store.scheduledRestartStatus()
            status = s
            shutdownWaitMinutes = max(1, s.shutdownWaitSeconds / 60)
            if let mine = s.schedules[vm.id] {
                enabled = mine.enabled
                weekdays = mine.weekdays
                time = Calendar.current.date(bySettingHour: mine.hour, minute: mine.minute, second: 0, of: .now) ?? time
            } else {
                enabled = false
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
        var all = status.schedules
        if enabled || all[vm.id] != nil {
            all[vm.id] = draft
        }
        do {
            try await store.installScheduledRestarts(all, shutdownWaitSeconds: shutdownWaitMinutes * 60)
            message = enabled ? "Saved. \(vm.displayName) restarts \(draft.label.lowercased())." : "Schedule turned off for \(vm.displayName)."
            await load()
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
