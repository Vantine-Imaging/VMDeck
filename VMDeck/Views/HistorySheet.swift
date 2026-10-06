import SwiftUI

/// A VM's power history and guest crashes, from Fusion's logs on the host.
struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let vm: VirtualMachine
    let store: VMStore

    @State private var history: VMHistory?
    @State private var loadError: String?
    @State private var problemsOnly = false

    private var shown: [VMEvent] {
        guard let history else { return [] }
        let events = problemsOnly ? history.events.filter { $0.kind.isProblem || $0.kind == .guestReboot || $0.kind == .resetRequest || $0.kind == .scheduled }
                                  : history.events
        return events.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History: \(vm.displayName)").font(.headline)
                Spacer()
                HelpButton(topic: HelpTopic.history)
            }
            .padding(16)

            if let history {
                summary(history)
                Divider()
                if shown.isEmpty {
                    ContentUnavailableView("Nothing recorded", systemImage: "clock",
                                           description: Text("Fusion hasn't logged any power events for this VM yet."))
                } else {
                    List(shown) { event in
                        row(event)
                    }
                    .listStyle(.inset)
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding()
                Spacer()
            } else {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading logs on \(store.host.name)").foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()
            HStack {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await load() } }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 640)
        .frame(minHeight: 420, idealHeight: 560, maxHeight: 800)
        .task { await load() }
    }

    private var footer: String {
        if let since = history?.since {
            return "From Fusion's logs for this VM on \(store.host.name), since \(since.formatted(date: .abbreviated, time: .shortened)). Times are in your local time zone."
        }
        return "From Fusion's logs for this VM on \(store.host.name)."
    }

    private func summary(_ history: VMHistory) -> some View {
        HStack(spacing: 20) {
            stat("Boots", history.boots, systemImage: "power")
            stat("Guest reboots", history.count(.guestReboot), systemImage: "arrow.clockwise.circle")
            stat("Suspends", history.count(.suspend), systemImage: "pause.circle")
            stat("Kernel panics", history.count(.panic), systemImage: "exclamationmark.triangle.fill",
                 tint: history.count(.panic) > 0 ? .red : nil)
            Spacer()
            Toggle("Problems and restarts only", isOn: $problemsOnly)
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func stat(_ title: String, _ value: Int, systemImage: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(value)).font(.title2).monospacedDigit().foregroundStyle(tint ?? .primary)
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ event: VMEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.kind.systemImage)
                .foregroundStyle(event.kind.isProblem ? .red : .secondary)
                .frame(width: 18)
            Text(event.date.formatted(date: .abbreviated, time: .standard))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind.label)
                    .fontWeight(event.kind.isProblem ? .semibold : .regular)
                    .foregroundStyle(event.kind.isProblem ? .red : .primary)
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.system(.caption, design: event.kind == .panic ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do {
            history = try await store.history(of: vm)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
