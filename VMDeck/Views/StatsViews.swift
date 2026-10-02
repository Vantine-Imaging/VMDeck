import SwiftUI

/// One-line host summary above the VM table.
struct HostStatsBar: View {
    let stats: HostStats?
    let vms: [VirtualMachine]

    var body: some View {
        HStack(spacing: 16) {
            if let stats {
                // Drops the least useful items first when the window is narrow.
                ViewThatFits(in: .horizontal) {
                    items(stats, detail: 2)
                    items(stats, detail: 1)
                    items(stats, detail: 0)
                }
            } else {
                Text("Loading host stats").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("\(vms.filter { $0.powerState == .running }.count) of \(vms.count) running")
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func items(_ stats: HostStats, detail: Int) -> some View {
        HStack(spacing: 16) {
            if detail >= 2 {
                Label(Format.model(stats.model), systemImage: "desktopcomputer")
                Label("macOS \(stats.osVersion)", systemImage: "apple.logo")
            }
            Label(detail >= 1 ? "\(stats.cpuCount) cores, load \(Format.load(stats.loadAverage.first))"
                              : "Load \(Format.load(stats.loadAverage.first))",
                  systemImage: "cpu")
                .help("1-minute load average on \(stats.cpuCount) cores. A load equal to the core count means every core is busy.")
            if let used = stats.memoryUsedBytes {
                Label(detail >= 1 ? "\(Format.bytes(used)) of \(Format.bytes(stats.memoryBytes)) used"
                                  : Format.bytes(used),
                      systemImage: "memorychip")
                    .help("Memory in use as Activity Monitor counts it: app, wired, and compressed.")
            }
            if detail >= 1, let boot = stats.bootTime {
                Label("Up \(Format.duration(Date.now.timeIntervalSince(boot)))", systemImage: "clock")
            }
        }
        .fixedSize()
    }
}

/// Inspector with the host's details and, when a VM is selected, its stats.
struct StatsInspector: View {
    let store: VMStore
    let selection: VirtualMachine.ID?
    let onEdit: (VirtualMachine) -> Void
    let onSchedule: (VirtualMachine) -> Void

    private var vm: VirtualMachine? {
        selection.flatMap { id in store.vms.first { $0.id == id } }
    }

    var body: some View {
        Form {
            if let vm {
                vmSections(vm)
            } else {
                Section {
                    Text("Select a VM to see its stats.")
                        .foregroundStyle(.secondary)
                }
            }
            hostSection
        }
        .formStyle(.grouped)
        .task(id: selection) {
            if let vm { await store.loadDiskUsage(for: vm) }
        }
    }

    @ViewBuilder
    private func vmSections(_ vm: VirtualMachine) -> some View {
        Section(vm.displayName) {
            LabeledContent("State") { StateBadge(state: vm.powerState) }
            if let ip = vm.ipAddress {
                LabeledContent("IP Address") {
                    Text(ip).textSelection(.enabled).monospacedDigit()
                }
                if vm.ipSource == .network {
                    Text("Found by MAC address on the host's network. VMware Tools isn't reporting an address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let target = RemoteDesktop.target(for: vm) {
                LabeledContent("Screen") {
                    Button("Connect", systemImage: "rectangle.inset.filled.and.person.filled") {
                        try? RemoteDesktop.open(target)
                    }
                    .disabled(target.handler == nil)
                    .help(target.help)
                }
                if target.handler == nil {
                    Text(target.help).font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Auto-start", value: vm.autoStart ? "At login" : "Off")
                .help("Change this with Auto-Start in the toolbar")
            LabeledContent("Schedule") {
                HStack(spacing: 8) {
                    Text(vm.restartSchedule.flatMap { $0.enabled ? $0.label : nil } ?? "Off")
                    Button("Edit", systemImage: "clock.arrow.2.circlepath") { onSchedule(vm) }
                        .help("Restart this VM on a recurring schedule")
                }
            }
            if vm.powerState == .running {
                LabeledContent("VMware Tools", value: (vm.tools ?? .unknown).label)
                if vm.tools == .installed {
                    Text("Tools is on disk but hasn't published anything this boot. Give a freshly started guest a minute; otherwise check the VMware Tools service inside it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if vm.powerState == .running {
            Section("Usage") {
                if let p = vm.process {
                    let vcpus = max(vm.config.vcpus ?? 1, 1)
                    MeterRow(title: "CPU", value: Format.percent(p.cpuShare(vcpus: vcpus)),
                             fraction: p.cpuShare(vcpus: vcpus) / 100)
                        .help("Use across the VM's \(vcpus) vCPUs. On the host that's \(Format.percent(p.cpuPercent)) of one core.")
                    LabeledContent("Host Memory", value: Format.bytes(p.residentBytes))
                        .help("Memory the VM's process is using on the host. Can exceed the configured amount because of graphics and other overhead.")
                    LabeledContent("Running For", value: Format.duration(p.uptime))
                } else {
                    Text("No usage data. The VM's process wasn't found on the host.")
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            LabeledContent("Guest OS", value: vm.config.guestOS.map(Format.guestOS) ?? "Unknown")
            LabeledContent("vCPUs", value: vm.config.vcpus.map(String.init) ?? "1")
            if let mb = vm.config.memoryMB {
                LabeledContent("Memory", value: Format.bytes(Int64(mb) * 1_048_576))
            }
            if !vm.config.macAddresses.isEmpty {
                LabeledContent("MAC Address") {
                    VStack(alignment: .trailing) {
                        ForEach(vm.config.macAddresses, id: \.self) { Text($0).monospaced() }
                    }
                    .textSelection(.enabled)
                }
            }
        } header: {
            Text("Configuration")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Button("Edit Resources", systemImage: "slider.horizontal.3") { onEdit(vm) }
                    .disabled(vm.powerState != .stopped)
                if vm.powerState == .running {
                    Text("Shut the VM down to change vCPUs, memory, or disk sizes.")
                } else if vm.powerState == .suspended {
                    Text("Start the VM and shut it down to change its resources. Hardware can't change while it's suspended.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Storage") {
            LabeledContent("VM Size") {
                if let bytes = store.diskUsage[vm.id] {
                    Text(Format.bytes(bytes))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let volume = vm.volume {
                LabeledContent("Volume", value: volume.mountPoint)
                MeterRow(title: "Free", value: "\(Format.bytes(volume.availableBytes)) of \(Format.bytes(volume.totalBytes))",
                         fraction: volume.totalBytes > 0 ? 1 - Double(volume.availableBytes) / Double(volume.totalBytes) : 0)
            }
            LabeledContent("Path") {
                Text(vm.vmxPath)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var hostSection: some View {
        if let stats = store.hostStats {
            Section(store.host.name) {
                LabeledContent("Model", value: Format.model(stats.model))
                LabeledContent("macOS", value: stats.osVersion)
                LabeledContent("CPU Cores", value: String(stats.cpuCount))
                LabeledContent("Load (1, 5, 15 min)", value: stats.loadAverage.map { Format.load($0) }.joined(separator: ", "))
                if let used = stats.memoryUsedBytes {
                    MeterRow(title: "Memory Used", value: "\(Format.bytes(used)) of \(Format.bytes(stats.memoryBytes))",
                             fraction: stats.memoryBytes > 0 ? Double(used) / Double(stats.memoryBytes) : 0)
                }
                if let boot = stats.bootTime {
                    LabeledContent("Up For", value: Format.duration(Date.now.timeIntervalSince(boot)))
                }
            }
        }
    }

}

/// A label, value, and thin bar underneath, in one form row.
struct MeterRow: View {
    let title: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title, value: value)
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
                .tint(fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor)
        }
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static func percent(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }

    static func load(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "–"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: max(seconds, 60)) ?? ""
    }

    /// "MacPro7,1" → "Mac Pro (MacPro7,1)".
    static func model(_ identifier: String) -> String {
        let names = ["MacPro": "Mac Pro", "Macmini": "Mac mini", "MacBookPro": "MacBook Pro",
                     "MacBookAir": "MacBook Air", "iMac": "iMac", "iMacPro": "iMac Pro", "MacStudio": "Mac Studio"]
        let family = identifier.prefix { $0.isLetter }
        guard let name = names[String(family)] else { return identifier }
        return "\(name) (\(identifier))"
    }

    /// Fusion guestOS identifiers → something readable; unknown ones pass through.
    static func guestOS(_ id: String) -> String {
        let lower = id.lowercased()
        let bits = lower.hasSuffix("-64") ? " (64-bit)" : ""
        let base = lower.replacingOccurrences(of: "-64", with: "")
        if base.hasPrefix("darwin"), let n = Int(base.dropFirst("darwin".count)) {
            // darwin16 = macOS 10.12 … darwin19 = 10.15, darwin20 = macOS 11.
            return n <= 19 ? "macOS 10.\(n - 4)" : "macOS \(n - 9)"
        }
        let known = ["windows9": "Windows 10", "windows11": "Windows 11", "windows8": "Windows 8",
                     "windows7": "Windows 7", "ubuntu": "Ubuntu", "debian": "Debian", "centos": "CentOS",
                     "rhel": "Red Hat Enterprise Linux", "other": "Other"]
        if let name = known.first(where: { base == $0.key || (base.hasPrefix($0.key) && base.dropFirst($0.key.count).allSatisfy(\.isNumber)) })?.value {
            return name + bits
        }
        return id
    }
}
