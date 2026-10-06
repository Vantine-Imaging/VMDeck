import AppKit
import SwiftUI

/// "A newer VMDeck is available", with the release notes and a Download button.
struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let release: AppRelease
    let checker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("VMDeck \(release.version) is available").font(.headline)
                    Text("You have \(checker.currentVersion). The installer is signed and notarized; run it and it replaces the copy in /Applications.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !release.notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 260)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("Skip This Version") { checker.skip(release); dismiss() }
                    .help("Don't mention \(release.version) again. Later versions still show.")
                Button("View on GitHub") { NSWorkspace.shared.open(release.pageURL) }
                Spacer()
                Button("Later") { checker.available = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") {
                    NSWorkspace.shared.open(release.installerURL ?? release.pageURL)
                    checker.available = nil
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help(release.installerURL == nil ? "Open the release page" : "Download the installer package")
            }
        }
        .padding(18)
        .frame(width: 540)
    }

    /// GitHub release notes are Markdown; render the inline parts and keep
    /// the structure readable.
    private var notes: AttributedString {
        let cleaned = release.notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = String(line)
                if l.hasPrefix("## ") { l.removeFirst(3); return "**\(l)**" }
                if l.hasPrefix("# ") { l.removeFirst(2); return "**\(l)**" }
                if l.hasPrefix("- ") { l.removeFirst(2); return "•  \(l)" }
                return l
            }
            .joined(separator: "\n")
        return (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cleaned)
    }
}
