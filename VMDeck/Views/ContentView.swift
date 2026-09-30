import AppKit
import SwiftUI

enum HostSheet: Identifiable {
    case add
    case edit(Host)
    /// The SSH setup assistant, for a new Mac or to repair an existing host.
    case sshSetup(Host?)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let host): host.id.uuidString
        case .sshSetup(let host): "setup-\(host?.id.uuidString ?? "new")"
        }
    }
}

struct ContentView: View {
    @Environment(HostStore.self) private var hostStore
    @State private var selection: Host.ID?
    @State private var sheet: HostSheet?
    /// Owned here so the sidebar stays as the user left it. Unbound, the split
    /// view re-derived it whenever the detail's layout changed (for example
    /// when the stats inspector opened) and popped the sidebar back open.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HostSidebar(selection: $selection, onAdd: { sheet = .add }, onSetUp: { sheet = .sshSetup(nil) })
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let id = selection, let host = hostStore.host(id) {
                HostDetailView(store: hostStore.store(for: host),
                               onEdit: { sheet = .edit(host) },
                               onSetUp: { sheet = .sshSetup(host) })
                    .id(host)
            } else {
                ContentUnavailableView {
                    Label(hostStore.hosts.isEmpty ? "No Hosts" : "No Host Selected", systemImage: "server.rack")
                } description: {
                    Text(hostStore.hosts.isEmpty
                         ? "Add this Mac, or set up a remote Mac running VMware Fusion. The setup assistant walks through SSH for a Mac you haven't connected to before."
                         : "Select a host to see its VMs.")
                } actions: {
                    if hostStore.hosts.isEmpty {
                        HStack {
                            Button("Set Up a Remote Mac") { sheet = .sshSetup(nil) }
                                .buttonStyle(.borderedProminent)
                            Button("Add Host") { sheet = .add }
                        }
                    }
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add:
                HostEditorSheet(original: nil) { host in
                    hostStore.add(host)
                    selection = host.id
                }
            case .edit(let host):
                HostEditorSheet(original: host) { hostStore.update($0) }
            case .sshSetup(let host):
                SSHSetupSheet(original: host) { saved in
                    if host == nil {
                        hostStore.add(saved)
                    } else {
                        hostStore.update(saved)
                    }
                    selection = saved.id
                }
            }
        }
        .focusedSceneValue(\.appCommands, AppCommandActions(
            addHost: { sheet = .add },
            setUpRemoteMac: { sheet = .sshSetup(nil) }))
        .onAppear {
            if selection == nil { selection = hostStore.hosts.first?.id }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "VMDeckSidebarHidden") { columnVisibility = .detailOnly }
            // `-VMDeckToggleSidebar YES`: press the toolbar's sidebar button after 2 s,
            // the way a user would, rather than setting the binding.
            if UserDefaults.standard.bool(forKey: "VMDeckToggleSidebar") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
            }
            // `open VMDeck.app --args -VMDeckOpenSetup YES`, for screenshots.
            if UserDefaults.standard.bool(forKey: "VMDeckOpenSetup") { sheet = .sshSetup(nil) }
            // `--args -VMDeckOpenHelp topic-id`
            if let topic = UserDefaults.standard.string(forKey: "VMDeckOpenHelp") {
                UserDefaults.standard.set(topic, forKey: HelpNavigation.topicKey)
                openWindow(id: VMDeckApp.helpWindowID)
            }
            #endif
        }
    }
}
