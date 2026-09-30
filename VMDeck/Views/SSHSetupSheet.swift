import AppKit
import SwiftUI

/// Walks through getting a Mac that's never been SSH'd into ready for VMDeck.
struct SSHSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SSHSetupModel
    @State private var browser = SSHServiceBrowser()
    @State private var nearbyFilter = ""
    private static let nearbyLimit = 6

    private var nearbyMatches: [String] {
        let filter = nearbyFilter.trimmed
        return filter.isEmpty ? browser.names : browser.names.filter { $0.localizedStandardContains(filter) }
    }
    let onSave: (Host) -> Void

    init(original: Host?, onSave: @escaping (Host) -> Void) {
        _model = State(initialValue: SSHSetupModel(original: original))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(current: model.step)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    HelpButton(topic: HelpTopic.sshSetup)
                        .padding(.trailing, 16)
                }
                .padding(.top, 16)
                .padding(.bottom, 4)
            Form {
                switch model.step {
                case .find: findStep
                case .trust: trustStep
                case .key: keyStep
                case .fusion: fusionStep
                }
                if let problem = model.problem {
                    ProblemSection(problem: problem)
                }
            }
            .formStyle(.grouped)
            .disabled(model.busy)
        }
        .frame(width: 560, height: 600)
        .onAppear { browser.start() }
        #if DEBUG
        .task {
            // `--args -VMDeckSetupHost 127.0.0.1 -VMDeckSetupPort 2222`, for screenshots.
            let defaults = UserDefaults.standard
            if let host = defaults.string(forKey: "VMDeckSetupHost") {
                model.hostname = host
                if defaults.integer(forKey: "VMDeckSetupPort") > 0 { model.port = defaults.integer(forKey: "VMDeckSetupPort") }
                await model.checkConnection()
            }
        }
        #endif
        .onDisappear { browser.stop() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if model.step != .find {
                ToolbarItem(placement: .navigation) {
                    Button("Back") { model.back() }
                        .disabled(model.busy)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                primaryButton
            }
        }
    }

    // MARK: - Primary action

    @ViewBuilder
    private var primaryButton: some View {
        HStack {
            if model.busy { ProgressView().controlSize(.small) }
            switch model.step {
            case .find:
                Button("Check Connection") { Task { await model.checkConnection() } }
                    .disabled(!model.canCheck)
            case .trust:
                Button("Trust and Continue") { Task { await model.trustAndContinue() } }
                    .disabled(model.busy)
            case .key:
                Button("Install Key") { Task { await model.installKey() } }
                    .disabled(model.busy || model.password.isEmpty)
            case .fusion:
                Button(model.original == nil ? "Add Host" : "Save") {
                    onSave(model.makeHost())
                    dismiss()
                }
                .disabled(model.busy || model.vmrunPath.trimmed.isEmpty)
            }
        }
    }

    // MARK: - Step 1: find

    @ViewBuilder
    private var findStep: some View {
        Section("Connection") {
            TextField("Hostname", text: $model.hostname, prompt: Text("Lab-Mac-mini.local"))
            TextField("User", text: $model.user)
            TextField("Port", value: $model.port, format: .number.grouping(.never))
        }

        Section {
            let matches = nearbyMatches
            if browser.names.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(browser.failure ?? "Looking for Macs on this network")
                        .foregroundStyle(.secondary)
                }
            } else {
                if browser.names.count > Self.nearbyLimit {
                    TextField("Filter", text: $nearbyFilter, prompt: Text("Filter \(browser.names.count) Macs"))
                }
                ForEach(matches.prefix(Self.nearbyLimit), id: \.self) { serviceName in
                    HStack {
                        Label(serviceName, systemImage: "desktopcomputer")
                        Spacer()
                        Button("Use") { Task { await model.useNearby(serviceName) } }
                    }
                }
                if matches.count > Self.nearbyLimit {
                    Text("\(matches.count - Self.nearbyLimit) more. Type to narrow the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if matches.isEmpty {
                    Text("No nearby Mac matches \u{201C}\(nearbyFilter)\u{201D}.")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Nearby Macs with Remote Login On")
        }

        Section {
            DisclosureGroup("Mac not listed, or never set up for SSH?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the other Mac:")
                    NumberedSteps([
                        "Open System Settings > General > Sharing.",
                        "Turn on Remote Login.",
                        "Click the info button next to Remote Login. Under Allow access for, make sure the account that owns the VMs is included.",
                        "If the VMs are in ~/Documents, also turn on Allow full disk access for remote users.",
                        "The Local hostname at the bottom of the Sharing pane is what goes in Hostname above.",
                    ])
                    Text("Macs on another network or VPN won't appear in the list. Enter their hostname or IP address instead.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Step 2: trust

    @ViewBuilder
    private var trustStep: some View {
        Section {
            Text("This Mac hasn't connected to \(model.hostname) before. Compare the fingerprint below with the one on that Mac. If they match, you're connecting to the right machine.")
        }
        Section("Host Key") {
            ForEach(model.hostKeys, id: \.self) { key in
                LabeledContent(key.type) {
                    Text(key.fingerprint)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        Section {
            CommandRow(command: "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
        } header: {
            Text("To Check, Run This in Terminal on \(model.hostname)")
        } footer: {
            Text("VMDeck saves the key to ~/.ssh/known_hosts. If it ever changes, VMDeck refuses to connect.")
        }
    }

    // MARK: - Step 3: key

    @ViewBuilder
    private var keyStep: some View {
        Section {
            Text("VMDeck signs in with a key, so it never has to store a password. Its key is at ~/.ssh/\(SSHSetup.keyName) on this Mac. The public half gets added to \(model.user)'s authorized keys on \(model.hostname).")
        }
        Section {
            SecureField("Password", text: $model.password, prompt: Text("\(model.user)'s password on \(model.hostname)"))
                .onSubmit {
                    if !model.password.isEmpty { Task { await model.installKey() } }
                }
        } footer: {
            Text("Used once to install the key. It isn't saved.")
        }
        Section {
            DisclosureGroup("Prefer to use Terminal?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run this and enter the password when asked:")
                    CommandRow(command: model.setup.terminalCommand(for: model.target))
                    Button("Check Again") { Task { await model.verifyKey() } }
                }
                .font(.callout)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Step 4: fusion

    @ViewBuilder
    private var fusionStep: some View {
        Section {
            Label("Signed in to \(model.target.destination)" + (model.identity == nil ? " with your existing SSH key." : " with VMDeck's key."),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            if let fusion = model.fusion {
                if let count = fusion.runningCount {
                    Label("VMware Fusion found. \(count == 1 ? "1 VM" : "\(count) VMs") running.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let error = fusion.error {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("vmrun didn't work over SSH.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Text("Install VMware Fusion on that Mac and open it once to finish setup, or correct the vmrun path below. You can still add the host and fix this later.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if fusion.documentsBlocked {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("SSH sessions can't read ~/Documents on that Mac.", systemImage: "folder.badge.questionmark")
                            .foregroundStyle(.orange)
                        Text("VMs stored in ~/Documents won't show up. To fix it, on that Mac open System Settings > General > Sharing, click the info button next to Remote Login, and turn on Allow full disk access for remote users.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for VMware Fusion").foregroundStyle(.secondary)
                }
            }
        }

        Section {
            TextField("Name", text: $model.name, prompt: Text(model.hostname))
            TextField("vmrun Path", text: $model.vmrunPath)
            Button("Check Again") { Task { await model.runFusionCheck() } }
        }
    }
}

// MARK: - Pieces

private struct StepHeader: View {
    let current: SSHSetupModel.Step

    var body: some View {
        HStack(spacing: 14) {
            ForEach(SSHSetupModel.Step.allCases) { step in
                let done = step.rawValue < current.rawValue
                let active = step == current
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(active || done ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 20, height: 20)
                        if done {
                            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue + 1)").font(.caption.bold())
                                .foregroundStyle(active ? .white : .secondary)
                        }
                    }
                    Text(step.title)
                        .font(.callout)
                        .foregroundStyle(active ? .primary : .secondary)
                }
            }
        }
    }
}

private struct ProblemSection: View {
    let problem: SSHSetupModel.Problem

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(problem.text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if let hint = problem.hint {
                    Text(hint).font(.callout).foregroundStyle(.secondary)
                }
                if let command = problem.command {
                    CommandRow(command: command)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct NumberedSteps: View {
    let steps: [String]
    init(_ steps: [String]) { self.steps = steps }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(text)
                }
            }
        }
    }
}

private struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
