import Charts
import SwiftUI

/// Resource use over time for one VM (CPU and host memory) and its host
/// (load and memory), from the recorder VMDeck installs on the host.
struct UsageSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// nil shows the host alone.
    let vm: VirtualMachine?
    let store: VMStore

    @State private var series: UsageSeries?
    @State private var loadError: String?
    @State private var range: UsageRange = .day
    @State private var working = false
    @State private var message: String?

    private var host: Host { store.host }
    private var title: String { vm.map { "Usage: \($0.displayName)" } ?? "Usage: \(host.name)" }
    private var vcpus: Int { max(vm?.config.vcpus ?? 1, 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(UsageRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                HelpButton(topic: HelpTopic.usage)
            }
            .padding(16)
            Divider()

            if let series {
                if !series.recording && series.vm.isEmpty && series.host.isEmpty {
                    notRecording
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if vm != nil {
                                chartSection("CPU", unit: "% of \(vcpus) vCPU\(vcpus == 1 ? "" : "s")", empty: series.vm.isEmpty) {
                                    Chart(series.vm) { s in
                                        LineMark(x: .value("Time", s.date), y: .value("CPU", min(s.cpuPercent / Double(vcpus), 100)))
                                            .interpolationMethod(.monotone)
                                        AreaMark(x: .value("Time", s.date), y: .value("CPU", min(s.cpuPercent / Double(vcpus), 100)))
                                            .interpolationMethod(.monotone)
                                            .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                                    }
                                    .chartYScale(domain: 0...100)
                                    .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                                        AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } } } }
                                }
                                chartSection("Host Memory", unit: "used by the VM's process", empty: series.vm.isEmpty) {
                                    Chart(series.vm) { s in
                                        LineMark(x: .value("Time", s.date), y: .value("Memory", Double(s.residentBytes) / 1_073_741_824))
                                            .interpolationMethod(.monotone)
                                            .foregroundStyle(.purple)
                                    }
                                    .chartYAxis { AxisMarks { v in
                                        AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(d.formatted(.number.precision(.fractionLength(0...1)))) GB") } } } }
                                }
                            }
                            chartSection("\(host.name) Load", unit: "1-minute load average, \(store.hostStats?.cpuCount ?? 0) cores", empty: series.host.isEmpty) {
                                Chart(series.host) { s in
                                    LineMark(x: .value("Time", s.date), y: .value("Load", s.load1))
                                        .interpolationMethod(.monotone)
                                        .foregroundStyle(.orange)
                                    if let cores = store.hostStats?.cpuCount {
                                        RuleMark(y: .value("Cores", Double(cores)))
                                            .foregroundStyle(.secondary.opacity(0.4))
                                            .lineStyle(StrokeStyle(dash: [4, 4]))
                                    }
                                }
                            }
                            chartSection("\(host.name) Memory", unit: "used (app, wired, compressed) and swap", empty: series.host.isEmpty) {
                                Chart {
                                    ForEach(series.host) { s in
                                        LineMark(x: .value("Time", s.date), y: .value("GB", Double(s.memoryUsedBytes) / 1_073_741_824), series: .value("Kind", "Used"))
                                            .interpolationMethod(.monotone)
                                            .foregroundStyle(by: .value("Kind", "Used"))
                                        LineMark(x: .value("Time", s.date), y: .value("GB", Double(s.swapUsedBytes) / 1_073_741_824), series: .value("Kind", "Swap"))
                                            .interpolationMethod(.monotone)
                                            .foregroundStyle(by: .value("Kind", "Swap"))
                                    }
                                    if let total = store.hostStats?.memoryBytes {
                                        RuleMark(y: .value("Total", Double(total) / 1_073_741_824))
                                            .foregroundStyle(.secondary.opacity(0.4))
                                            .lineStyle(StrokeStyle(dash: [4, 4]))
                                    }
                                }
                                .chartForegroundStyleScale(["Used": Color.teal, "Swap": Color.red])
                                .chartYAxis { AxisMarks { v in
                                    AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) GB") } } } }
                            }
                        }
                        .padding(16)
                    }
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled).padding()
                Spacer()
            } else {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading samples on \(host.name)").foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()
            HStack {
                if let series {
                    Label(statusText(series), systemImage: series.recording ? "record.circle" : "record.circle.fill")
                        .font(.caption)
                        .foregroundStyle(series.recording ? .green : .secondary)
                    if series.recording {
                        Button("Stop Recording") { Task { await setRecording(false) } }
                            .controlSize(.small)
                            .help("Remove the once-a-minute recorder from \(host.name). Samples already taken are kept.")
                    } else if !(series.vm.isEmpty && series.host.isEmpty) {
                        Button("Start Recording") { Task { await setRecording(true) } }
                            .controlSize(.small)
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(message.hasPrefix("Couldn't") ? .red : .secondary)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await load() } }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 720)
        .frame(minHeight: 480, idealHeight: 720, maxHeight: 900)
        .disabled(working)
        .task(id: range) { await load() }
    }

    private var notRecording: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.xyaxis.line").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Not recording on \(host.name)").font(.title3)
            Text("VMDeck can install a small once-a-minute recorder on the host that notes each VM's CPU and memory and the host's load and memory, so usage can be charted even while VMDeck isn't running. It runs in the host user's login session, keeps three months of samples (a few megabytes a month) in ~/Library/Logs/VMDeck/usage/, and does nothing else.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Button("Start Recording") { Task { await setRecording(true) } }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private func chartSection<C: View>(_ title: String, unit: String, empty: Bool, @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if empty {
                Text(vm != nil && title == "CPU" || title == "Host Memory" ? "No samples for this VM in this range. It may not have been running." : "No samples in this range.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(height: 60)
            } else {
                chart()
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: xFormat) } }
                    .frame(height: 150)
            }
        }
    }

    private var xFormat: Date.FormatStyle {
        switch range {
        case .hour, .day: .dateTime.hour().minute()
        case .week, .month: .dateTime.month(.abbreviated).day()
        }
    }

    private func statusText(_ s: UsageSeries) -> String {
        if s.recording {
            let since = s.since.map { "since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "just started"
            return s.loaded ? "Recording every minute, \(since)" : "Recorder installed, starts at next login"
        }
        if let since = s.since { return "Not recording. Samples kept from \(since.formatted(date: .abbreviated, time: .shortened))." }
        return "Not recording"
    }

    private func load() async {
        do {
            series = try await store.usage(for: vm, range: range)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func setRecording(_ on: Bool) async {
        working = true
        message = nil
        do {
            try await store.setUsageRecording(on)
            message = on ? "Recording. The first points appear within a couple of minutes." : "Recorder removed."
            await load()
        } catch {
            message = "Couldn't change recording: \(error.localizedDescription)"
        }
        working = false
    }
}
