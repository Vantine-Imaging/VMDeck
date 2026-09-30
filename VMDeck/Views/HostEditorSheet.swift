import SwiftUI

struct HostEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let original: Host?
    let onSave: (Host) -> Void

    @State private var name: String
    @State private var isRemote: Bool
    @State private var user: String
    @State private var hostname: String
    @State private var port: Int
    @State private var vmrunPath: String
    @State private var extraPaths: [String]

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing
        case success(String)
        case failure(String)
    }

    init(original: Host?, onSave: @escaping (Host) -> Void) {
        self.original = original
        self.onSave = onSave
        let host = original ?? Host(name: "", kind: .ssh(SSHTarget(user: NSUserName(), hostname: "")))
        _name = State(initialValue: host.name)
        _vmrunPath = State(initialValue: host.vmrunPath)
        _extraPaths = State(initialValue: host.extraVMXPaths)
        switch host.kind {
        case .local:
            _isRemote = State(initialValue: false)
            _user = State(initialValue: NSUserName())
            _hostname = State(initialValue: "")
            _port = State(initialValue: 22)
        case .ssh(let target):
            _isRemote = State(initialValue: true)
            _user = State(initialValue: target.user)
            _hostname = State(initialValue: target.hostname)
            _port = State(initialValue: target.port)
        }
    }

    private var draft: Host {
        var identity: String?
        if let original, case .ssh(let t) = original.kind { identity = t.identityFile }
        let kind: Host.Kind = isRemote
            ? .ssh(SSHTarget(user: user.trimmed, hostname: hostname.trimmed, port: port, identityFile: identity))
            : .local
        var host = original ?? Host(name: "", kind: kind)
        host.name = name.trimmed.isEmpty ? (isRemote ? hostname.trimmed : "This Mac") : name.trimmed
        host.kind = kind
        host.vmrunPath = vmrunPath.trimmed
        host.extraVMXPaths = extraPaths
        return host
    }

    private var isValid: Bool {
        !vmrunPath.trimmed.isEmpty && (!isRemote || (!hostname.trimmed.isEmpty && (1...65535).contains(port)))
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(isRemote ? "Lab Mac mini" : "This Mac"))
                Picker("Connection", selection: $isRemote) {
                    Text("This Mac").tag(false)
                    Text("SSH").tag(true)
                }
                .pickerStyle(.segmented)
            }

            if isRemote {
                Section {
                    TextField("Hostname", text: $hostname, prompt: Text("macmini.local"))
                    TextField("User", text: $user)
                    TextField("Port", value: $port, format: .number.grouping(.never))
                } footer: {
                    Text("Uses your SSH keys and ~/.ssh/config. Haven't connected to this Mac before? Cancel and use Set Up Mac, which sets up Remote Login, the host key, and a sign-in key.")
                }
            }

            Section {
                TextField("vmrun Path", text: $vmrunPath)
                if vmrunPath.trimmed != Host.defaultVMRunPath {
                    Button("Use Default Path") { vmrunPath = Host.defaultVMRunPath }
                        .buttonStyle(.link)
                }
            }

            if !extraPaths.isEmpty {
                Section("Added VM Paths") {
                    ForEach(extraPaths, id: \.self) { path in
                        HStack {
                            Text(path).lineLimit(1).truncationMode(.middle).help(path)
                            Spacer()
                            Button("Remove") { extraPaths.removeAll { $0 == path } }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button("Test Connection", action: test)
                        .disabled(!isValid || testState == .testing)
                    testStatus
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onChange(of: draft) { testState = .idle }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(original == nil ? "Add Host" : "Save") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func test() {
        let vmrun = draft.vmrun
        testState = .testing
        Task {
            do {
                let running = try await vmrun.list()
                testState = .success(running.count == 1 ? "Connected, 1 VM running" : "Connected, \(running.count) VMs running")
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
