import SwiftUI

/// Remembers which topic the Help window shows, so a help button elsewhere
/// can open it on the right page.
enum HelpNavigation {
    static let topicKey = "VMDeckHelpTopic"
}

struct HelpView: View {
    @AppStorage(HelpNavigation.topicKey) private var topicID = HelpTopic.gettingStarted

    private var topic: HelpTopic {
        HelpTopic.all.first { $0.id == topicID } ?? HelpTopic.all[0]
    }

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.all, selection: Binding(get: { topicID }, set: { topicID = $0 ?? topicID })) { topic in
                Label(topic.title, systemImage: topic.systemImage).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(topic.title, systemImage: topic.systemImage)
                        .font(.largeTitle.bold())
                        .padding(.bottom, 4)
                    ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                        HelpBlockView(block: block)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(topic.id)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct HelpBlockView: View {
    let block: HelpTopic.Block

    var body: some View {
        switch block {
        case .paragraph(let text):
            md(text)
        case .heading(let text):
            Text(text).font(.title3.bold()).padding(.top, 8)
        case .steps(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        md(item)
                    }
                }
            }
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        md(item)
                    }
                }
            }
        case .note(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
                md(text)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .code(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func md(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The standard round ? button, opening the Help window on `topic`.
struct HelpButton: View {
    let topic: String
    @Environment(\.openWindow) private var openWindow
    @AppStorage(HelpNavigation.topicKey) private var topicID = HelpTopic.gettingStarted

    var body: some View {
        HelpLink {
            topicID = topic
            openWindow(id: VMDeckApp.helpWindowID)
        }
    }
}
