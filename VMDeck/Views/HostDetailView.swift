import SwiftUI

struct HostDetailView: View {
    @Environment(HostStore.self) private var hostStore
    let store: VMStore
    let onEdit: () -> Void
    let onSetUp: () -> Void

    @State private var confirmingRemove = false
    @State private var addingPath = false
    @State private var selection: VirtualMachine.ID?
    /// Part of the layout, not a reaction to clicks: opening it on the first
    /// selection resized the window mid-click, which stuttered and could
    /// unsettle the sidebar. Remembered across launches.
    @AppStorage("showStats") private var showStats = true
    @State private var editing: VirtualMachine?
    @State private var showAutomation = false
    @State private var automating: VirtualMachine?
    @State private var showingHistory: VirtualMachine?

    var body: some View {
        content
            .navigationTitle(store.host.name)
            .navigationSubtitle(store.host.subtitle)
            .toolbar {
                // Icon-only in the toolbar, so each needs .help for its tooltip.
                ToolbarItemGroup {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.refresh() }
                    }
                    .help("Refresh now (⌘R). VMDeck also refreshes every 5 seconds.")
                    Button("Add VM Path", systemImage: "plus.rectangle.on.folder") { addingPath = true }
                        .help("Add a VM stored somewhere VMDeck doesn't look")
                    Button("Automation", systemImage: "clock.badge.checkmark") { showAutomation = true }
                        .help("What this host's VMs do on their own: start at login, restart on a schedule")
                    Button("Edit Host", systemImage: "pencil", action: onEdit)
                        .help("Edit this host's connection settings (⌘E)")
                    Button("Remove Host", systemImage: "trash") { confirmingRemove = true }
                        .help("Stop managing this host. Its VMs aren't touched.")
                }
                ToolbarItem {
                    Button(showStats ? "Hide Stats" : "Show Stats", systemImage: "sidebar.trailing") {
                        showStats.toggle()
                    }
                    .help(showStats ? "Hide host and VM stats (⌥⌘I)" : "Show host and VM stats (⌥⌘I)")
                }
            }
            .task { await store.poll() }
            .focusedSceneValue(\.hostCommands, HostCommandActions(
                refresh: { Task { await store.refresh() } },
                addVMPath: { addingPath = true },
                editHost: onEdit,
                automation: { showAutomation = true },
                toggleStats: { showStats.toggle() },
                statsShown: showStats))
            .inspector(isPresented: $showStats) {
                StatsInspector(store: store, selection: selection, onEdit: { editing = $0 }, onAutomate: { automating = $0 }, onHistory: { showingHistory = $0 })
                    .inspectorColumnWidth(min: 250, ideal: 290, max: 420)
            }
            #if DEBUG
            // `--args -VMDeckSelect "Name"`, for screenshots.
            .onChange(of: store.vms) { _, vms in
                if selection == nil, let name = UserDefaults.standard.string(forKey: "VMDeckSelect"),
                   let id = vms.first(where: { $0.displayName == name })?.id {
                    // `-VMDeckSelectDelay <seconds>` orders it after other debug actions.
                    let delay = UserDefaults.standard.double(forKey: "VMDeckSelectDelay")
                    UserDefaults.standard.removeObject(forKey: "VMDeckSelect")
                    Task {
                        try? await Task.sleep(for: .seconds(delay))
                        selection = id
                    }
                }
                // `--args -VMDeckOpenAutomation YES` opens the host's Automation sheet (read-only until Save).
                if UserDefaults.standard.bool(forKey: "VMDeckOpenAutomation") {
                    UserDefaults.standard.removeObject(forKey: "VMDeckOpenAutomation")
                    showAutomation = true
                }
                // `--args -VMDeckAutomate "Name"` opens a VM's Automation sheet (read-only until Save).
                if automating == nil, let name = UserDefaults.standard.string(forKey: "VMDeckAutomate") {
                    automating = vms.first { $0.displayName == name }
                    UserDefaults.standard.removeObject(forKey: "VMDeckAutomate")
                }
                // `--args -VMDeckHistory "Name"` opens a VM's History sheet.
                if showingHistory == nil, let name = UserDefaults.standard.string(forKey: "VMDeckHistory") {
                    showingHistory = vms.first { $0.displayName == name }
                    UserDefaults.standard.removeObject(forKey: "VMDeckHistory")
                }
                // `--args -VMDeckEdit "Name"` opens the resource editor (read-only until Apply).
                if editing == nil, let name = UserDefaults.standard.string(forKey: "VMDeckEdit") {
                    editing = vms.first { $0.displayName == name }
                    UserDefaults.standard.removeObject(forKey: "VMDeckEdit")
                }
            }
            #endif
            .confirmationDialog("Remove \(store.host.name)?", isPresented: $confirmingRemove) {
                Button("Remove Host", role: .destructive) { hostStore.remove(store.host.id) }
            } message: {
                Text("VMDeck stops managing this host. Its VMs aren't touched.")
            }
            .sheet(isPresented: $showAutomation) {
                AutomationOverviewSheet(store: store)
            }
            .sheet(item: $automating) { vm in
                AutomationSheet(vm: vm, store: store)
            }
            .sheet(item: $showingHistory) { vm in
                HistorySheet(vm: vm, store: store)
            }
            .sheet(item: $editing) { vm in
                EditResourcesSheet(vm: vm, store: store)
            }
            .sheet(isPresented: $addingPath) {
                AddVMPathSheet { path in
                    var host = store.host
                    if !host.extraVMXPaths.contains(path) {
                        host.extraVMXPaths.append(path)
                        hostStore.update(host)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded {
            ProgressView("Loading VMs")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.hostError, store.vms.isEmpty {
            ContentUnavailableView {
                Label("Can't Reach Host", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                HStack {
                    Button("Retry") { Task { await store.refresh() } }
                    if case .ssh = store.host.kind {
                        Button("Run SSH Setup", action: onSetUp)
                    }
                }
            }
        } else if store.vms.isEmpty {
            ContentUnavailableView {
                Label("No VMs Found", systemImage: "desktopcomputer")
            } description: {
                Text("VMDeck looks in ~/Virtual Machines.localized, ~/Documents/Virtual Machines.localized, /Users/Shared/Virtual Machines, and Fusion's library. Use Add VM Path for VMs stored elsewhere.")
            }
        } else {
            VStack(spacing: 0) {
                if let error = store.hostError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Last refresh failed: \(error)").lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button("Retry") { Task { await store.refresh() } }
                    }
                    .padding(8)
                    .background(.yellow.opacity(0.12))
                }
                HostStatsBar(stats: store.hostStats, vms: store.vms)
                Divider()
                VMTable(store: store, selection: $selection, onEdit: { editing = $0 }, showUsage: !showStats)
            }
        }
    }
}

struct AddVMPathSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String) -> Void
    @State private var path = ""

    private var trimmed: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            TextField("Path to .vmx", text: $path, prompt: Text("/Volumes/VMs/Linux.vmwarevm/Linux.vmx"))
            Text("The path on the host itself, so for a remote host it's the path on that Mac. ~/ is allowed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    onAdd(trimmed)
                    dismiss()
                }
                .disabled(!trimmed.hasSuffix(".vmx"))
            }
        }
    }
}
