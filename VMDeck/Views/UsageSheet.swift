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
    /// When the series was loaded: the right edge of every chart's x axis.
    @State private var loadedAt = Date()

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
                                        AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { yLabel("\(Int(d))%") } } } }
                                    .modifier(hover(series.vm, date: \.date) { [vcpus] h in
                                        "\(Int((min(h.cpuPercent / Double(vcpus), 100)).rounded()))%"
                                    })
                                }
                                chartSection("Host Memory", unit: "used by the VM's process", empty: series.vm.isEmpty) {
                                    Chart(series.vm) { s in
                                        LineMark(x: .value("Time", s.date), y: .value("Memory", Double(s.residentBytes) / 1_073_741_824))
                                            .interpolationMethod(.monotone)
                                            .foregroundStyle(.purple)
                                    }
                                    .chartYAxis { AxisMarks { v in
                                        AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { yLabel("\(d.formatted(.number.precision(.fractionLength(0...1)))) GB") } } } }
                                    .modifier(hover(series.vm, date: \.date) { Format.bytes($0.residentBytes) })
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
                                .chartYAxis { AxisMarks { v in
                                    AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { yLabel(d.formatted(.number.precision(.fractionLength(0...1)))) } } } }
                                .modifier(hover(series.host, date: \.date) { "load \(Format.load($0.load1))" })
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
                                    AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { yLabel("\(Int(d)) GB") } } } }
                                .modifier(hover(series.host, date: \.date) { h in
                                    h.swapUsedBytes > 0
                                        ? "\(Format.bytes(h.memoryUsedBytes)) used, \(Format.bytes(h.swapUsedBytes)) swap"
                                        : "\(Format.bytes(h.memoryUsedBytes)) used"
                                })
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
        .task(id: "\(range.rawValue)|\(vm?.id ?? "")") { await load() }
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
                    .chartXScale(domain: xDomain)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: xFormat) } }
                    .frame(height: 150)
            }
        }
    }

    /// The same span on every chart, so their time axes line up whichever
    /// series has samples where.
    private var xDomain: ClosedRange<Date> {
        loadedAt.addingTimeInterval(-Double(range.seconds))...loadedAt
    }

    /// A y-axis label in a fixed-width frame, so every chart's plot area is
    /// the same width and the time axes line up.
    private func yLabel(_ text: String) -> some View {
        Text(text).monospacedDigit().lineLimit(1).frame(width: 44, alignment: .leading)
    }

    private func hover<T>(_ items: [T], date: KeyPath<T, Date>, label: @escaping (T) -> String) -> ChartHover<T> {
        ChartHover(items: items, date: date, maxGap: Double(range.bucketSeconds) * 2, format: hoverFormat, label: label)
    }

    private var hoverFormat: Date.FormatStyle {
        switch range {
        case .hour, .day: .dateTime.hour().minute()
        case .week, .month: .dateTime.month(.abbreviated).day().hour().minute()
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
            var loaded = try await store.usage(for: vm, range: range)
            // The hover lookup binary-searches by date.
            if !loaded.vm.isSorted(by: { $0.date <= $1.date }) { loaded.vm.sort { $0.date < $1.date } }
            if !loaded.host.isSorted(by: { $0.date <= $1.date }) { loaded.host.sort { $0.date < $1.date } }
            loadedAt = Date()
            series = loaded
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

private extension Array {
    /// True when each neighbouring pair satisfies `inOrder`.
    func isSorted(by inOrder: (Element, Element) -> Bool) -> Bool {
        zip(self, dropFirst()).allSatisfy { inOrder($0, $1) }
    }
}

/// The hover crosshair for one chart: a vertical rule at the nearest sample
/// with "time  value" in a pill above it. It lives in the chart's overlay with
/// its own state, so moving the pointer redraws only this layer of the hovered
/// chart, never the marks or the other charts.
struct ChartHover<T>: ViewModifier {
    let items: [T]
    let date: KeyPath<T, Date>
    /// Hovering further than this from any sample (a gap) shows nothing.
    let maxGap: TimeInterval
    let format: Date.FormatStyle
    let label: (T) -> String

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            ChartHoverLayer(proxy: proxy, items: items, date: date, maxGap: maxGap, format: format, label: label)
        }
    }
}

private struct ChartHoverLayer<T>: View {
    let proxy: ChartProxy
    let items: [T]
    let date: KeyPath<T, Date>
    let maxGap: TimeInterval
    let format: Date.FormatStyle
    let label: (T) -> String

    @State private var pointerX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point) where plot.contains(point): pointerX = point.x - plot.minX
                        default: pointerX = nil
                        }
                    }
                if let pointerX, let hit = nearest(toPlotX: pointerX), let x = proxy.position(forX: hit[keyPath: date]) {
                    let lineX = plot.minX + x
                    let plotTop = plot.minY
                    Rectangle()
                        .fill(.secondary.opacity(0.6))
                        .frame(width: 1, height: plot.height)
                        .offset(x: lineX - 0.5, y: plot.minY)
                        .allowsHitTesting(false)
                    Text("\(hit[keyPath: date].formatted(format))  \(label(hit))")
                        .font(.caption)
                        .monospacedDigit()
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        // Centred on the rule, kept within the plot's width (clear of the
                        // y labels, whose top one sits at this height), just above the plot.
                        .alignmentGuide(.leading) { d in -max(min(lineX - d.width / 2, plot.maxX - d.width), plot.minX) }
                        .alignmentGuide(.top) { d in -(plotTop - 2 - d.height) }
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// The sample closest to the time under the pointer, by binary search
    /// over the date-sorted samples.
    private func nearest(toPlotX x: CGFloat) -> T? {
        guard !items.isEmpty, let target = proxy.value(atX: x, as: Date.self) else { return nil }
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid][keyPath: date] < target { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { items.indices.contains($0) }
        guard let best = candidates.min(by: {
            abs(items[$0][keyPath: date].timeIntervalSince(target)) < abs(items[$1][keyPath: date].timeIntervalSince(target))
        }) else { return nil }
        // Don't point at a sample from another day when hovering a gap.
        guard abs(items[best][keyPath: date].timeIntervalSince(target)) <= maxGap else { return nil }
        return items[best]
    }
}
