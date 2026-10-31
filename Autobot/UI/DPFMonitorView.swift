// DPFMonitorView.swift
// The DPF monitor (DPFMonitor): live DPF back pressure and engine RPM in large type and as charts on
// one shared time axis, back pressure against RPM, soot and regeneration, exhaust temperatures, and the
// raw PCM replies. Reading runs only while this screen is open.

import Charts
import SwiftUI

private typealias Tuning = AppConfig.DPF

/// Dashboard row: soot / regeneration at a glance; opens the DPF monitor.
struct DPFMonitorButton: View {
    @ObservedObject var monitor: DPFMonitor
    @ObservedObject var log: DPFRegenLog
    @ObservedObject var finder: DPFHistoryFinder
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack {
                Label("DPF monitor", systemImage: "aqi.medium")
                Spacer()
                Text(summary)
                    .font(.subheadline)
                    .foregroundColor(monitor.reading.regenerating == true ? .orange : .secondary)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .font(.headline)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            DPFMonitorView(monitor: monitor, log: log, finder: finder)
        }
    }

    private var summary: String {
        if monitor.reading.regenerating == true { return "Regenerating" }
        if let soot = monitor.reading.soot { return String(format: "Soot %.1f g/L", soot) }
        return "Back pressure · soot"
    }
}

struct DPFMonitorView: View {
    @ObservedObject var monitor: DPFMonitor
    @ObservedObject var log: DPFRegenLog
    @ObservedObject var finder: DPFHistoryFinder
    @Environment(\.dismiss) private var dismiss
    @State private var showingFinder = false
    @State private var window: TimeInterval = Tuning.chartWindows.first ?? 60
    @State private var selected: Date?

    private let pressureColor = Color.indigo
    private let rpmColor = Color.teal

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headline
                    if monitor.reading.regenerating == true { regenBanner }
                    liveCharts
                    pressureVersusRPM
                    dpfCard
                    historyCard
                    temperatureCard
                    rawCard
                }
                .padding()
            }
            .navigationTitle("DPF monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            monitor.start()
            finder.refresh()
        }
        .onDisappear { monitor.stop() }
        .sheet(isPresented: $showingFinder) {
            DPFHistoryFinderView(finder: finder)
        }
    }

    // MARK: Headline

    private var headline: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                tile("DPF back pressure", value: number(monitor.reading.pressure?.differential, "%.2f"),
                     unit: "kPa", caption: monitor.peakPressure.map { String(format: "peak %.2f kPa", $0) })
                tile("Engine speed", value: number(monitor.reading.rpm, "%.0f"), unit: "rpm",
                     caption: monitor.reading.soot.map { String(format: "soot %.2f g/L", $0) })
            }
            Text(monitor.status)
                .font(.caption)
                .foregroundColor(monitor.isRunning && !monitor.points.isEmpty ? .green : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tile(_ title: String, value: String, unit: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(caption ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }

    private var regenBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flame.fill").font(.title2).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Regenerating").font(.headline)
                    if let started = monitor.regenStartedAt {
                        Text(started, style: .timer).font(.headline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("The DPF is burning off soot. Keep driving if you can rather than switching off.")
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(12)
    }

    // MARK: Charts

    /// The points inside the chosen window, ending at the latest read.
    private var visible: [DPFMonitor.Point] {
        let start = domain.lowerBound
        return monitor.points.filter { $0.time >= start }
    }

    private var domain: ClosedRange<Date> {
        let end = monitor.points.last?.time ?? Date()
        return end.addingTimeInterval(-window)...end
    }

    /// The read closest to where the chart is being touched.
    private var selectedPoint: DPFMonitor.Point? {
        guard let selected else { return nil }
        return visible.min { abs($0.time.timeIntervalSince(selected)) < abs($1.time.timeIntervalSince(selected)) }
    }

    /// Stretches of the window during which a regeneration was running, for shading.
    private var regenSpans: [(start: Date, end: Date)] {
        var spans: [(start: Date, end: Date)] = []
        var start: Date?
        var last: Date?
        for point in visible {
            if point.regenerating {
                if start == nil { start = point.time }
            } else if let s = start {
                spans.append((s, point.time))
                start = nil
            }
            last = point.time
        }
        if let start, let last { spans.append((start, last)) }
        return spans
    }

    private var liveCharts: some View {
        card("Live") {
            Picker("Window", selection: $window) {
                ForEach(Tuning.chartWindows, id: \.self) { seconds in
                    Text(seconds < 120 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min").tag(seconds)
                }
            }
            .pickerStyle(.segmented)

            Group {
                if let point = selectedPoint {
                    Text(selectionText(point))
                } else {
                    Text("Touch and drag a chart to read a moment")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            timeChart(title: "Back pressure (kPa)", color: pressureColor, value: \.pressure, format: "%.2f")
            timeChart(title: "Engine speed (rpm)", color: rpmColor, value: \.rpm, format: "%.0f")

            if !regenSpans.isEmpty {
                Label("Shaded: regeneration running", systemImage: "flame")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "20:15:42  ·  2.35 kPa  ·  1850 rpm" for the read being touched.
    private func selectionText(_ point: DPFMonitor.Point) -> String {
        var parts: [String] = []
        parts.append(point.time.formatted(.dateTime.hour().minute().second()))
        parts.append(number(point.pressure, "%.2f", " kPa"))
        parts.append(number(point.rpm, "%.0f", " rpm"))
        if point.regenerating { parts.append("regenerating") }
        return parts.joined(separator: "  ·  ")
    }

    private func timeChart(title: String, color: Color, value: KeyPath<DPFMonitor.Point, Double?>,
                           format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            Chart {
                ForEach(Array(regenSpans.enumerated()), id: \.offset) { item in
                    RectangleMark(xStart: .value("Start", item.element.start),
                                  xEnd: .value("End", item.element.end))
                        .foregroundStyle(Color.orange.opacity(0.15))
                }
                ForEach(visible.filter { $0[keyPath: value] != nil }) { point in
                    LineMark(x: .value("Time", point.time), y: .value(title, point[keyPath: value] ?? 0))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let point = selectedPoint {
                    RuleMark(x: .value("Time", point.time))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                    if let y = point[keyPath: value] {
                        PointMark(x: .value("Time", point.time), y: .value(title, y))
                            .foregroundStyle(color)
                            .symbolSize(70)
                    }
                }
            }
            .chartXScale(domain: domain)
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel(format: .dateTime.hour().minute().second())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel()
                }
            }
            .frame(height: 160)
            .overlay {
                if visible.allSatisfy({ $0[keyPath: value] == nil }) {
                    Text(monitor.isRunning ? "Waiting for data…" : "Not monitoring")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pressureVersusRPM: some View {
        card("Back pressure vs RPM") {
            let pairs = visible.filter { $0.rpm != nil && $0.pressure != nil }
            Chart(pairs) { point in
                PointMark(x: .value("rpm", point.rpm ?? 0), y: .value("kPa", point.pressure ?? 0))
                    .foregroundStyle(by: .value("State", point.regenerating ? "Regenerating" : "Normal"))
                    .symbol(by: .value("State", point.regenerating ? "Regenerating" : "Normal"))
                    .symbolSize(28)
                    .opacity(0.75)
            }
            .chartForegroundStyleScale(["Normal": pressureColor, "Regenerating": Color.orange])
            .chartXAxisLabel("rpm")
            .chartYAxisLabel("kPa")
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 200)
            Text("Back pressure rises with exhaust flow, so compare it at the same RPM over time: higher "
                 + "than usual at the same RPM means more soot (or ash) in the filter. Right after a "
                 + "regeneration it should be at its lowest.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Values

    private var dpfCard: some View {
        card("DPF") {
            sootGauge
            row("Soot generated", number(monitor.reading.sootGenerated, "%.2f", " g/L"), value: .sootGenerated)
            row("Since last regeneration", number(monitor.reading.regenDistance, "%.0f", " km"), value: .regenDistance)
            row("Regenerations", monitor.reading.regenCount.map { "\($0)" } ?? "--", value: .regenCount)
            row("Regeneration", regenText, value: .regenStatus)
            if let inlet = monitor.reading.pressure?.inlet {
                row("Inlet pressure", String(format: "%.2f kPa", inlet), value: nil)
            }
            if let outlet = monitor.reading.pressure?.outlet {
                row("Outlet pressure", String(format: "%.2f kPa", outlet), value: nil)
            }
            row("Peak back pressure (this session)", number(monitor.peakPressure, "%.2f", " kPa"), value: nil)
        }
    }

    @ViewBuilder
    private var sootGauge: some View {
        if let soot = monitor.reading.soot {
            let level = sootLevel(soot)
            Gauge(value: min(max(soot, 0), Tuning.sootFullScale), in: 0...Tuning.sootFullScale) {
                HStack {
                    Text("Soot accumulated")
                    Spacer()
                    Text(String(format: "%.2f g/L", soot)).monospacedDigit()
                }
                .font(.subheadline)
            } currentValueLabel: {
                Label(level.text, systemImage: level.icon).font(.caption).foregroundStyle(.secondary)
            }
            .gaugeStyle(.linearCapacity)
            .tint(level.color)
        } else {
            row("Soot accumulated", "--", value: .soot)
        }
    }

    private func sootLevel(_ soot: Double) -> (text: String, icon: String, color: Color) {
        if soot >= Tuning.sootCritical {
            return ("Very high: give it a long drive at steady speed", "exclamationmark.octagon", .red)
        }
        if soot >= Tuning.sootHigh { return ("High: a regeneration is due", "exclamationmark.triangle", .orange) }
        return ("OK", "checkmark.circle", .green)
    }

    private var regenText: String {
        guard let running = monitor.reading.regenerating else { return "--" }
        let raw = monitor.reading.raw[MazdaDPF.Value.regenStatus.did]?.first.map { String(format: " (%02X)", $0) } ?? ""
        return (running ? "Running" : "Not running") + raw
    }

    // MARK: Regeneration history

    /// One bar of a regeneration-interval chart: 1 = the newest.
    private struct IntervalBar: Identifiable {
        let id: Int
        let km: Double
    }

    private var historyCard: some View {
        card("Regeneration history") {
            Text("From the PCM · last \(Tuning.historyEntries)").font(.subheadline.bold())
            if let history = finder.history {
                intervalChart(history.enumerated().map { IntervalBar(id: $0.offset + 1, km: $0.element) })
                Text(pcmHistoryNote).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Not found yet. Where the PCM keeps it isn't published, so Autobot finds it on the car: "
                     + "scan once, and the next regeneration confirms which value it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(finder.learned == nil ? "Find it in the PCM" : "History finder") { showingFinder = true }
                .buttonStyle(.bordered)
                .font(.caption)

            Divider()

            Text("Recorded by Autobot").font(.subheadline.bold())
            let known = log.entries.prefix(Tuning.historyEntries).enumerated().compactMap { item -> IntervalBar? in
                item.element.intervalKm.map { IntervalBar(id: item.offset + 1, km: $0) }
            }
            if !known.isEmpty { intervalChart(known) }
            if log.entries.isEmpty {
                Text("Nothing yet. From now on every regeneration is recorded with the distance driven before "
                     + "it (read once a minute while driving).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(log.entries.prefix(20)) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.date.formatted(.dateTime.day().month().hour().minute()))
                    Spacer()
                    Text(DPFRegenLog.describe(entry)).monospacedDigit()
                }
                .font(.caption)
            }
            Text(logStatus).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Bars of km between regenerations, newest (1) on the left, with the average as a line.
    private func intervalChart(_ bars: [IntervalBar]) -> some View {
        let average = bars.isEmpty ? nil : bars.map(\.km).reduce(0, +) / Double(bars.count)
        return Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Regeneration", String(format: "%02d", bar.id)), y: .value("km", bar.km),
                        width: .ratio(0.6))
                    .foregroundStyle(pressureColor)
                    .cornerRadius(4)
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(String(format: "avg %.0f km", average)).font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartYAxisLabel("km")
        .frame(height: 150)
    }

    private var pcmHistoryNote: String {
        var text = "01 = newest."
        if let read = finder.historyRead { text += " Read " + read.formatted(.dateTime.day().month().hour().minute()) + "." }
        if finder.learned?.confirmed == false { text += " Picked by hand: not confirmed by a regeneration yet." }
        return text + " The Torque preset these come from read 30 km more than Mazda's dealer tool."
    }

    private var logStatus: String {
        var parts: [String] = []
        if let distance = log.lastDistance { parts.append(String(format: "now %.0f km since the last one", distance)) }
        if let count = log.lastCount { parts.append("\(count) so far") }
        if let read = log.lastRead { parts.append("read " + read.formatted(.dateTime.day().month().hour().minute())) }
        return parts.isEmpty ? "Not read yet" : parts.joined(separator: " · ")
    }

    private var temperatureCard: some View {
        card("Temperatures") {
            let egt = monitor.reading.exhaustTemps.sorted { $0.key < $1.key }
            if egt.isEmpty {
                row("Exhaust gas", "--", value: .exhaustTemps)
            }
            ForEach(egt, id: \.key) { entry in
                row("Exhaust gas, sensor \(entry.key)", String(format: "%.0f °C", entry.value), value: nil)
            }
            row("DPF inlet", number(monitor.reading.dpfInletTemp, "%.0f", " °C"), value: .dpfTemps)
            row("DPF outlet", number(monitor.reading.dpfOutletTemp, "%.0f", " °C"), value: .dpfTemps)
            row("Coolant", number(monitor.reading.coolant, "%.0f", " °C"), value: .coolant)
        }
    }

    private var rawCard: some View {
        card("Raw PCM replies") {
            ForEach(MazdaDPF.Value.allCases) { value in
                LabeledContent("\(MazdaDPF.header) 22\(value.did)") {
                    Text(rawText(value)).font(.system(.caption, design: .monospaced))
                }
                .font(.caption)
            }
            Text("The Mazda DPF values (04xx, 0380) and their scaling come from community PID lists for "
                 + "SkyActiv-D cars. If a value looks off, compare it with FORScan; the raw bytes are here "
                 + "for that. RPM is the standard PID 01 0C.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func rawText(_ value: MazdaDPF.Value) -> String {
        if monitor.unanswered.contains(value) { return "not answered" }
        guard let bytes = monitor.reading.raw[value.did] else { return "--" }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: Helpers

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }

    /// One value; "not answered" in place of "--" when the PCM refused it.
    private func row(_ title: String, _ text: String, value: MazdaDPF.Value?) -> some View {
        var shown = text
        if text == "--", let value, monitor.unanswered.contains(value) { shown = "not answered" }
        return LabeledContent(title) {
            Text(shown).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func number(_ value: Double?, _ format: String, _ unit: String = "") -> String {
        value.map { String(format: format, $0) + unit } ?? "--"
    }
}

/// Finds where the PCM keeps its last 10 regeneration distances (DPFHistoryFinder): scan once (in
/// parts if need be), then the next regeneration confirms the candidate that moved along by one entry.
struct DPFHistoryFinderView: View {
    @ObservedObject var finder: DPFHistoryFinder
    @Environment(\.dismiss) private var dismiss
    @State private var manualDIDs = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(finder.message)
                    if let progress {
                        ProgressView(value: progress.value) { Text(progress.label).font(.caption) }
                        if isScanning {
                            Button("Pause (keeps what's done)", role: .cancel) { finder.cancel() }
                        }
                    }
                }
                if let learned = finder.learned {
                    Section("In use") {
                        LabeledContent(DPFHistoryFinder.title(learned.header, learned.did, learned.span),
                                       value: learned.confirmed ? "confirmed" : "picked by hand")
                        if let history = finder.history {
                            Text(historyText(history))
                                .font(.system(.caption, design: .monospaced))
                        }
                        Button("Forget", role: .destructive) { finder.forget() }
                            .disabled(finder.isBusy)
                    }
                }
                Section {
                    Toggle("Extended session (10 03)", isOn: $finder.extendedSession)
                        .disabled(finder.isBusy)
                    Button(scanTitle) { finder.scan() }
                        .disabled(finder.isBusy)
                    Button("Read the candidates again now") { finder.refresh() }
                        .disabled(finder.isBusy || finder.candidates.isEmpty)
                } header: {
                    Text("Find it")
                } footer: {
                    Text(scanFooter)
                }
                if let state = finder.scanState {
                    scanSection(state)
                }
                if !finder.candidates.isEmpty {
                    Section("Candidates, best first") {
                        ForEach(finder.candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                manualSection
                if finder.scanState != nil || !finder.candidates.isEmpty {
                    Section {
                        Button("Start over (forget the scan and candidates)", role: .destructive) {
                            finder.resetCandidates()
                        }
                        .disabled(finder.isBusy)
                    }
                }
            }
            .navigationTitle("Regeneration history")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = finder.phase { return true }
        return false
    }

    private var scanFooter: String {
        let plan = "Scans \(DPFHistoryFinder.planText) (\(DPFHistoryFinder.planCount) DIDs) a chunk at a time, "
        var text = "Car parked, engine running (ignition only drains the battery over this long). " + plan
        text += "so live data and Power Mode keep going. Pause, driving off or losing the adapter keeps "
        text += "what's done; Scan carries on from there. Looks for one DID holding 10 distances, or a row "
        text += "of 10 DIDs holding one each. Then just drive: after the next regeneration the candidates "
        text += "are read again, and the one whose entries moved along by one is used automatically.\n\n"
        text += "Extended session: some values only answer there (dealer tools use it). Reading only; the "
        text += "PCM drops back to normal by itself a few seconds after the last request. Switching it "
        text += "starts the scan from the start again (what was found is kept)."
        return text
    }

    private var scanTitle: String {
        if finder.resumes, let state = finder.scanState {
            return "Carry on scanning (\(state.done) / \(state.total), about \(finder.minutesLeft) min)"
        }
        if finder.scanState?.isComplete == true, finder.scanState?.extended == finder.extendedSession {
            return "Scan again from the start (about \(finder.minutesLeft) min)"
        }
        return "Scan the PCM (about \(finder.minutesLeft) min, can be done in parts)"
    }

    private func scanSection(_ state: DPFHistoryFinder.ScanState) -> some View {
        Section {
            LabeledContent("Asked", value: "\(state.done) / \(state.total)")
            LabeledContent("Session", value: state.extended ? "extended (10 03)" : "default")
            LabeledContent("Answer", value: "\(state.answers.count)")
            LabeledContent("Change by themselves", value: "\(state.unsteady.count)")
            LabeledContent("Refused", value: "\(state.refused.count)")
            if !state.refused.isEmpty {
                DisclosureGroup("Refused DIDs (they exist, but not like this)") {
                    ForEach(refusedLines(state), id: \.self) { line in
                        Text(line).font(.system(.caption2, design: .monospaced))
                    }
                }
            }
            if let url = finder.exportURL {
                ShareLink("Export raw scan (send to me)", item: url)
            }
        } header: {
            Text("Scan so far")
        } footer: {
            Text("Refused with 7F/7E (not in this session) or 33 (security): try the extended session. "
                 + "The export has every reply, for looking through by hand.")
        }
    }

    private var manualSection: some View {
        Section {
            HStack {
                TextField("0435 or 0435-043E", text: $manualDIDs)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button("Read") { finder.readByHand(manualDIDs) }
                    .buttonStyle(.borderless)
                    .disabled(finder.isBusy || manualDIDs.isEmpty)
            }
            ForEach(finder.manualReads) { read in
                VStack(alignment: .leading, spacing: 2) {
                    Text(read.request).font(.caption.bold())
                    Text(read.result).font(.system(.caption2, design: .monospaced))
                }
            }
        } header: {
            Text("Read by hand")
        } footer: {
            Text("Reads PCM (7E0) DIDs as they are — one, a range or several, up to 64 — in the extended "
                 + "session when it's switched on above.")
        }
    }

    private func refusedLines(_ state: DPFHistoryFinder.ScanState) -> [String] {
        state.refused.keys.sorted().map { key in
            let code = state.refused[key] ?? 0
            return key + String(format: "  7F 22 %02X ", code) + ELM327.negativeResponseName(code)
        }
    }

    private func candidateRow(_ candidate: DPFHistoryFinder.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(DPFHistoryFinder.title(candidate.header, candidate.did, candidate.span))
                    .font(.subheadline.bold())
                Spacer()
                Text(verdictText(candidate))
                    .font(.caption)
                    .foregroundColor(candidate.verdict == true || candidate.oneEntryChanged == true
                                     ? .green : .secondary)
            }
            Text(DPFHistoryFinder.plausibility(candidate)).font(.caption).foregroundStyle(.secondary)
            Text(DPFHistoryFinder.hex(candidate.bytes))
                .font(.system(.caption2, design: .monospaced))
            Text(DPFHistoryFinder.kmPreview(candidate))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if finder.learned?.id != candidate.id, candidate.verdict != false {
                Button("Use this one") { finder.use(candidate) }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(finder.isBusy)
            }
        }
    }

    private func verdictText(_ candidate: DPFHistoryFinder.Candidate) -> String {
        switch candidate.verdict {
        case true?: return "✓ shifted after a regeneration"
        case false?: return "ruled out"
        case nil:
            if candidate.oneEntryChanged == true { return "one entry changed after a regeneration" }
            return candidate.unshiftedChecks > 0
                ? "not shifted yet (\(candidate.unshiftedChecks))"
                : "waiting for a regeneration"
        }
    }

    private func historyText(_ history: [Double]) -> String {
        history.enumerated()
            .map { String(format: "%02d: %.0f km", $0.offset + 1, $0.element) }
            .joined(separator: "\n")
    }

    private var progress: (value: Double, label: String)? {
        switch finder.phase {
        case .idle:
            return nil
        case .scanning(let done, let total, let next):
            var label = "Scanning \(done) / \(total) · next \(next)"
            if let left = finder.timeLeft {
                label += " · about \(max(1, Int((left / 60).rounded(.up)))) min left"
            }
            return (total > 0 ? Double(done) / Double(total) : 0, label)
        case .reading:
            return (1, "Reading the PCM…")
        }
    }
}
