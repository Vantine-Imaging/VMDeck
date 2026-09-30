import SwiftUI

struct HostSidebar: View {
    @Environment(HostStore.self) private var hostStore
    @Binding var selection: Host.ID?
    let onAdd: () -> Void
    let onSetUp: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Hosts") {
                ForEach(hostStore.hosts) { host in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.name)
                            Text(host.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: host.systemImage)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if let error = hostStore.existingStore(for: host.id)?.hostError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help("Can't reach \(host.name): \(error)")
                        }
                    }
                    .tag(host.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button("Add Host", systemImage: "plus", action: onAdd)
                    .help("Add this Mac or a Mac you can already SSH into (⌘N)")
                Button("Set Up Remote Mac", systemImage: "wand.and.sparkles", action: onSetUp)
                    .help("Set up SSH to a Mac you haven't connected to before (⇧⌘N)")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }
}
