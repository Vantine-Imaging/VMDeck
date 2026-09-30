import SwiftUI

@main
struct VMDeckApp: App {
    static let helpWindowID = "help"

    @State private var hostStore = HostStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(hostStore)
                .frame(minWidth: 820, minHeight: 420)
        }
        .defaultSize(width: 1200, height: 620)
        .commands { VMDeckCommands() }

        Window("VMDeck Help", id: Self.helpWindowID) {
            HelpView()
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
    }
}

/// Window-level actions, published by ContentView.
struct AppCommandActions {
    var addHost: () -> Void
    var setUpRemoteMac: () -> Void
}

/// Actions for the host on screen, published by HostDetailView.
struct HostCommandActions {
    var refresh: () -> Void
    var addVMPath: () -> Void
    var editHost: () -> Void
    var toggleStats: () -> Void
    var statsShown: Bool
}

extension FocusedValues {
    @Entry var appCommands: AppCommandActions?
    @Entry var hostCommands: HostCommandActions?
}

struct VMDeckCommands: Commands {
    @FocusedValue(\.appCommands) private var app
    @FocusedValue(\.hostCommands) private var host

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Host") { app?.addHost() }
                .keyboardShortcut("n")
                .disabled(app == nil)
            Button("Set Up Remote Mac") { app?.setUpRemoteMac() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(app == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(host?.statsShown == true ? "Hide Stats" : "Show Stats") { host?.toggleStats() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(host == nil)
        }

        CommandMenu("Host") {
            Button("Refresh") { host?.refresh() }
                .keyboardShortcut("r")
                .disabled(host == nil)
            Divider()
            Button("Add VM Path") { host?.addVMPath() }
                .disabled(host == nil)
            Button("Edit Host") { host?.editHost() }
                .keyboardShortcut("e")
                .disabled(host == nil)
        }

        CommandGroup(replacing: .help) {
            HelpMenuItems()
        }
    }
}

private struct HelpMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(HelpNavigation.topicKey) private var topicID = HelpTopic.gettingStarted

    var body: some View {
        Button("VMDeck Help") {
            openWindow(id: VMDeckApp.helpWindowID)
        }
        .keyboardShortcut("?", modifiers: .command)
        Divider()
        ForEach(HelpTopic.all.dropFirst()) { topic in
            Button(topic.title) {
                topicID = topic.id
                openWindow(id: VMDeckApp.helpWindowID)
            }
        }
    }
}
