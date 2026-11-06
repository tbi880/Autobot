// DPFMonitorView.swift
// The DPF monitor (DPFMonitor): live DPF back pressure and engine RPM in large type and as charts on
// one shared time axis, back pressure against RPM, soot load and regeneration, the regeneration log,
// temperatures, EGR / boost / air flow / oil, and the raw PCM replies. Reading runs only while this screen is open.

import Charts
import SwiftUI

private typealias Tuning = AppConfig.DPF

/// Dashboard row: soot / regeneration at a glance; opens the DPF monitor.
struct DPFMonitorButton: View {
    @ObservedObject var monitor: DPFMonitor
    @ObservedObject var log: DPFRegenLog
    @ObservedObject var finder: DPFHistoryFinder
    @ObservedObject var recorder: DPFRecorder
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack {
                Label("DPF monitor", systemImage: "aqi.medium")
                Spacer()
                EngineHealthBadge(health: recorder.health)
                Text(summary)
                    .font(.subheadline)
                    .foregroundColor(regenerating ? .orange : .secondary)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .font(.headline)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            DPFMonitorView(monitor: monitor, log: log, finder: finder, recorder: recorder)
        }
    }

    private var regenerating: Bool { monitor.reading.regenerating == true || log.active != nil }

    private var summary: String {
        if regenerating { return "Regenerating" }
        if let rate = recorder.rate.sinceRegen, (recorder.rate.sinceKm ?? recorder.rate.regenKm ?? 0) >= Tuning.pmGenVerdictMinKm {
            return String(format: "PM_GEN %.1f g/L/100 km", rate)
        }
        if let generated = monitor.reading.sootGenerated { return String(format: "PM_GEN %.2f g/L", generated) }
        if let soot = monitor.reading.soot { return String(format: "PM_ACC %.2f g/L", soot) }
        return "Back pressure · soot"
    }
}

struct DPFMonitorView: View {
    @ObservedObject var monitor: DPFMonitor
    @ObservedObject var log: DPFRegenLog
    @ObservedObject var finder: DPFHistoryFinder
    @ObservedObject var recorder: DPFRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var showingFinder = false
    @State private var confirmingClear = false
    @State private var window: TimeInterval = Tuning.chartWindows.first ?? 60
    @State private var selected: Date?

    private let pressureColor = Color.indigo
    private let rpmColor = Color.teal

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headline
                    if regenerating { regenBanner }
                    if !healthNotes.isEmpty { healthCard }
                    engineHealthCard
                    liveCharts
                    pressureVersusRPM
                    dpfCard
                    pmGenCard
                    recorderCard
                    checkCard
                    historyCard
                    temperatureCard
                    engineCard
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
            recorder.screenOpened()
        }
        .onDisappear {
            monitor.stop()
            recorder.screenClosed()
        }
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
                tile("Engine speed", value: number(monitor.reading.rpm, "%.0f"), unit: "rpm", caption: sootCaption)
            }
            Text(monitor.status)
                .font(.caption)
                .foregroundColor(monitor.isRunning && !monitor.points.isEmpty ? .green : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "PM_GEN 2.80 g/L" (else PM_ACC) under the RPM tile.
    private var sootCaption: String? {
        if let generated = monitor.reading.sootGenerated { return String(format: "PM_GEN %.2f g/L", generated) }
        return monitor.reading.soot.map { String(format: "PM_ACC %.2f g/L", $0) }
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

    private var regenerating: Bool { monitor.reading.regenerating == true || log.active != nil }

    private var regenBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flame.fill").font(.title2).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Regenerating").font(.headline)
                    if let started = log.active?.start ?? monitor.regenStartedAt {
                        Text(started, style: .timer).font(.headline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let line = activeText { Text(line).font(.caption.monospacedDigit()) }
                Text(monitor.reading.regenerating == false
                     ? "The flag is off while stopped; the regeneration carries on once you drive again."
                     : "The DPF is burning off soot. Keep driving if you can rather than switching off: an "
                       + "interrupted regeneration adds fuel to the oil.")
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(12)
    }

    /// "PM_GEN 5.61 at start · PM_ACC 4.40 → 2.10 · peak EGT 612 °C · after 117 km"
    private var activeText: String? {
        guard let a = log.active else { return nil }
        var parts: [String] = []
        if let generated = a.sootGeneratedBefore { parts.append(String(format: "PM_GEN %.2f at start", generated)) }
        if let soot = a.sootBefore {
            parts.append(String(format: "PM_ACC %.2f", soot) + (monitor.reading.soot.map { String(format: " → %.2f", $0) } ?? ""))
        } else if let now = monitor.reading.soot {
            parts.append(String(format: "PM_ACC now %.2f", now))
        }
        if let peak = a.peakExhaustTemp { parts.append(String(format: "peak EGT %.0f °C", peak)) }
        if let km = a.distanceBefore { parts.append(String(format: "after %.0f km", km)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var healthNotes: [String] {
        var notes = log.healthNotes()
        if let soot = monitor.reading.sootLoad, soot >= Tuning.sootWarning {
            notes.insert(soot >= Tuning.sootCritical
                         ? String(format: "Soot %.1f g/L (PM_GEN): at 10 g/L or more the PCM stops regenerating by "
                                  + "itself — see a dealer.", soot)
                         : String(format: "Soot %.1f g/L (PM_GEN): the DPF light comes on from 8 g/L. A long drive "
                                  + "at steady speed lets it regenerate.", soot), at: 0)
        }
        if let now = sinceRegenNow, now.km >= Tuning.pmGenVerdictMinKm, now.rate >= Tuning.pmGenRateHigh {
            notes.append(pmGenNote(rate: now.rate))
        }
        return notes
    }

    private var healthCard: some View {
        card("Worth a look") {
            ForEach(healthNotes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle").font(.caption)
            }
        }
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
            row("Soot accumulated (PM_ACC)", number(monitor.reading.soot, "%.2f", " g/L"), value: .soot)
            row("Soot generated (PM_GEN)", number(monitor.reading.sootGenerated, "%.2f", " g/L"), value: .sootGenerated)
            row(MazdaDPF.Value.sootDesired.label, number(monitor.reading.sootDesired, "%.2f", " g/L"), value: .sootDesired)
            if let ratio = desiredRatio {
                Text(String(format: "PM_ACC_DSD is %.1f× PM_GEN. Mazda's test for the DPF pressure sensor (DTC "
                            + "P243C) flags twice PM_GEN or more at a steady 3,000 rpm: the parked check below.", ratio))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            row("Since last regeneration", number(monitor.reading.regenDistance, "%.1f", " km"), value: .regenDistance)
            row("Regenerations", monitor.reading.regenCount.map { "\($0)" } ?? "--", value: .regenCount)
            row("Regeneration flag", regenText, value: .regenStatus)
            if let inlet = monitor.reading.pressure?.inlet {
                row("Inlet pressure", String(format: "%.2f kPa", inlet), value: nil)
            }
            if let outlet = monitor.reading.pressure?.outlet {
                row("Outlet pressure", String(format: "%.2f kPa", outlet), value: nil)
            }
            row("Peak back pressure (this session)", number(monitor.peakPressure, "%.2f", " kPa"), value: nil)
            row("Exhaust pressure (upstream)", number(monitor.reading.exhaustPressure, "%.2f", " kPa"), value: .exhaustPressure)
            row("Odometer", number(monitor.reading.odometer, "%.0f", " km"), value: .odometer)
            if AppConfig.Odometer.offsetKm != 0, let shown = monitor.reading.odometerShown {
                Text(String(format: "Cluster %.0f km + %.0f km (AppConfig.Odometer.offsetKm: the odometer was "
                            + "adjusted).", shown, AppConfig.Odometer.offsetKm))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            aftertreatmentRows
        }
    }

    /// PID 8B, if this PCM answers it.
    @ViewBuilder
    private var aftertreatmentRows: some View {
        if let status = monitor.reading.aftertreatment {
            if let running = status.regenerating {
                row("PID 8B regeneration", (running ? "running" : "not running")
                    + (status.active.map { $0 ? " · active" : " · passive" } ?? ""), value: nil)
            }
            if let trigger = status.triggerPercent { row("PID 8B trigger", String(format: "%.0f %%", trigger), value: nil) }
            if let km = status.averageKm { row("PID 8B average interval", String(format: "%.0f km", km), value: nil) }
            if let minutes = status.averageMinutes {
                row("PID 8B average time between", String(format: "%.0f min", minutes), value: nil)
            }
        } else {
            row("Aftertreatment status (PID 8B)", "--", value: .aftertreatment)
        }
    }

    /// PM_GEN (else PM_ACC) against the ~5.6 g/L a regeneration starts at.
    @ViewBuilder
    private var sootGauge: some View {
        if let soot = monitor.reading.sootLoad {
            let level = sootLevel(soot)
            Gauge(value: min(max(soot, 0), Tuning.sootFullScale), in: 0...Tuning.sootFullScale) {
                HStack {
                    Text(monitor.reading.sootGenerated != nil ? "Soot generated (PM_GEN)" : "Soot accumulated (PM_ACC)")
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
            row("Soot generated (PM_GEN)", "--", value: .sootGenerated)
        }
    }

    private func sootLevel(_ soot: Double) -> (text: String, icon: String, color: Color) {
        if soot >= Tuning.sootCritical {
            return ("10+ g/L: no more automatic regeneration — dealer", "exclamationmark.octagon", .red)
        }
        if soot >= Tuning.sootWarning {
            return ("DPF light range: a long steady drive", "exclamationmark.triangle", .red)
        }
        if soot >= Tuning.pmGenTrigger { return ("A regeneration is due", "flame", .orange) }
        if soot >= Tuning.sootHigh {
            return (String(format: "Close to the ~%.1f g/L a regeneration starts at", Tuning.pmGenTrigger), "flame", .yellow)
        }
        return (String(format: "OK · a regeneration starts at about %.1f g/L", Tuning.pmGenTrigger), "checkmark.circle", .green)
    }

    /// "On, automatic (02)": byte A bit 0 is the forced request, bit 1 the automatic one.
    private var regenText: String {
        guard let running = monitor.reading.regenerating else { return "--" }
        let data = monitor.reading.raw[MazdaDPF.Value.regenStatus.did] ?? []
        let raw = data.first.map { String(format: " (%02X)", $0) } ?? ""
        guard running else { return "Off" + raw }
        return "On" + (MazdaDPF.regenKind(data).map { ", " + $0 } ?? "") + raw
    }

    /// PM_ACC_DSD ÷ PM_GEN from this screen's latest reads.
    private var desiredRatio: Double? {
        guard let desired = monitor.reading.sootDesired, let generated = monitor.reading.sootGenerated,
              generated > 0.2 else { return nil }
        return desired / generated
    }

    // MARK: PM_GEN growth and the data recorder

    /// PM_GEN per 100 km since the last regeneration and the distance it's over: from this screen's own
    /// latest reads, else the recorder's.
    private var sinceRegenNow: (rate: Double, km: Double)? {
        let r = monitor.reading
        if let generated = r.sootGenerated, let km = r.regenDistance, km >= Tuning.rateMinSinceRegenKm {
            return (generated / km * 100, km)
        }
        if let rate = recorder.rate.sinceRegen, let km = recorder.rate.sinceKm ?? recorder.rate.regenKm { return (rate, km) }
        return nil
    }

    private var pmGenCard: some View {
        card("PM_GEN growth") {
            let rate = recorder.rate
            row("Since the last regeneration", perHundred(sinceRegenNow?.rate), value: nil)
            row(String(format: "Last %.0f km", Tuning.rateWindowKm), recentText(rate), value: nil)
            row(String(format: "Per hour (last %.0f min)", Tuning.rateWindowMinutes),
                number(rate.perHour, "%.2f", " g/L/h"), value: nil)
            row(String(format: "%.1f g/L in about", Tuning.pmGenTrigger), number(rate.kmToTrigger, "%.0f", " km"),
                value: nil)
            row("PM_ACC ÷ PM_GEN (pressure ÷ model)", accRatioText, value: nil)
            if let fuel = rate.fuelSinceRegen {
                row("Fuel since the last regeneration", String(format: "%.1f L", fuel), value: nil)
            }
            if let perLitre = rate.perLitre {
                row("PM_GEN per litre of fuel", String(format: "%.3f g/L per L", perLitre), value: nil)
            }
            if let verdict = pmGenVerdict {
                Label(verdict.text, systemImage: verdict.icon)
                    .font(.caption)
                    .foregroundColor(verdict.color)
            }
            Text(pmGenExplanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func pmGenNote(rate: Double) -> String {
        String(format: """
            PM_GEN is growing %.1f g/L per 100 km, so the PCM's soot model reaches the ~%.1f g/L that starts a \
            regeneration after about %.0f km (owners report 250–400 km, about %.1f–%.1f g/L per 100 km). The \
            model works from engine speed, intake air and injected fuel: look at those (air flow, boost, EGR, \
            injectors) more than at the filter.
            """, rate, Tuning.pmGenTrigger, Tuning.pmGenTrigger / rate * 100,
            Tuning.pmGenHealthyRate.lowerBound, Tuning.pmGenHealthyRate.upperBound)
    }

    private var pmGenExplanation: String {
        String(format: """
            PM_GEN is the soot the PCM's model says the engine has made since the last regeneration, worked \
            out from engine speed, intake air and injected fuel (Mazda workshop manual). A regeneration starts \
            when it reaches about %.1f g/L with the oil warm (owner logs; the recorder's "0380 request" event \
            shows this car's). Owners report a regeneration every 250–400 km in mixed driving, about %.1f–%.1f \
            g/L per 100 km: an estimate, not a Mazda figure. PM_ACC is the soot worked out from the DPF \
            pressure; well below PM_GEN is normal (some soot burns off by itself), well above it points at \
            the filter or its pressure sensor. The data recorder works the rates out every %.0f s.
            """, Tuning.pmGenTrigger, Tuning.pmGenHealthyRate.lowerBound, Tuning.pmGenHealthyRate.upperBound,
            Tuning.recordInterval)
    }

    /// "0.81" from this screen's latest PM_ACC and PM_GEN.
    private var accRatioText: String {
        guard let acc = monitor.reading.soot, let generated = monitor.reading.sootGenerated, generated > 0.2 else {
            return "--"
        }
        return String(format: "%.2f", acc / generated)
    }

    private var recorderExplanation: String {
        String(format: """
            Every %.0f s while live data runs, screen open or not (every %.0f s around a regeneration): \
            PM_GEN, PM_ACC, PM_ACC_DSD, the regeneration flag, count and distance, exhaust and DPF \
            temperatures and pressure, air flow, EGR, boost, coolant, oil temperature and pressure; every \
            %.0f s also intake shutter, rail pressure and more (whatever this PCM answers), with every raw \
            reply and when it came in. With the ignition off nothing is recorded and \
            nothing is dropped. A slow sweep through the PCM's 0300–04FF and DA00–DAFF DIDs looks for where \
            it keeps the exhaust temperatures, the DPF pressure and the injected fuel. Export shares the CSV \
            and a JSON with the drives, events and regeneration log.
            """, Tuning.recordInterval, Tuning.recordIntervalDuringRegen, Tuning.recordNormalInterval)
    }

    private func perHundred(_ value: Double?) -> String {
        number(value, "%.2f", " g/L/100 km")
    }

    private func recentText(_ rate: DPFRecorder.Rate) -> String {
        guard let recent = rate.recent else { return "--" }
        return perHundred(recent) + (rate.recentKm.map { String(format: " (%.0f km)", $0) } ?? "")
    }

    private var pmGenVerdict: (text: String, icon: String, color: Color)? {
        guard let now = sinceRegenNow, now.km >= Tuning.pmGenVerdictMinKm, now.rate > 0 else { return nil }
        let healthy = Tuning.pmGenHealthyRate
        if now.rate >= Tuning.pmGenRateHigh {
            return (String(format: "About %.1f× the top of what owners report: at this pace a regeneration every ~%.0f km.",
                           now.rate / healthy.upperBound, Tuning.pmGenTrigger / now.rate * 100),
                    "exclamationmark.triangle", .orange)
        }
        if now.rate > healthy.upperBound {
            return ("A little faster than owners report.", "exclamationmark.circle", .yellow)
        }
        return ("Within what owners report.", "checkmark.circle", .green)
    }

    private var recorderCard: some View {
        card("Data recorder") {
            Text(recorder.status)
                .font(.caption)
                .foregroundColor(recorder.isRecording ? .green : .secondary)
            row("Samples", "\(recorder.sampleCount) · this drive \(recorder.driveSamples)", value: nil)
            row("Last sample", recorder.lastSample.map { $0.formatted(date: .omitted, time: .standard) } ?? "--",
                value: nil)
            row("Recorded", ByteCountFormatter.string(fromByteCount: Int64(recorder.fileBytes), countStyle: .file),
                value: nil)
            row("PCM DID sweep", recorder.sweepSummary, value: nil)
            ShareLink(items: shareItems) {
                Label("Export data (send to me)", systemImage: "square.and.arrow.up")
            }
            .disabled(shareItems.isEmpty)
            Button("Clear recorded data", role: .destructive) { confirmingClear = true }
                .font(.caption)
            Text(recorderExplanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Delete all recorded samples?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { recorder.clear() }
        }
    }

    /// The recorder's files, plus the history finder's raw scan when there is one.
    private var shareItems: [URL] {
        recorder.exportFiles + [finder.exportURL].compactMap { $0 }
    }

    // MARK: Parked check

    private var checkCard: some View {
        card("Parked check (3,000 rpm)") {
            if let ends = recorder.checkEnds {
                HStack {
                    Label("Recording back to back", systemImage: "record.circle").foregroundColor(.red)
                    Spacer()
                    Text(ends, style: .timer).monospacedDigit()
                }
                .font(.subheadline)
                row("Samples", "\(recorder.checkSamples)", value: nil)
                row("Engine speed", number(checkValue("rpm"), "%.0f", " rpm"), value: nil)
                row("Air flow (MAF)", number(checkValue("maf_a_gs"), "%.1f", " g/s"), value: nil)
                row("Boost target / actual", checkPair("boost_target_kpa", "boost_kpa", "%.0f", " kPa"), value: nil)
                row("DPF back pressure", number(checkValue("dpf_dp_kpa"), "%.2f", " kPa"), value: nil)
                row("EGR A / B", checkPair("egr_a_act_pct", "egr_b_act_pct", "%.0f", " %"), value: nil)
                row("Exhaust temperatures", checkEGTText, value: nil)
                row("Exhaust flow · DPF sensor", checkFlowText, value: nil)
                row("Exhaust O2 · fuel injected", checkO2FuelText, value: nil)
                row("PM_GEN / PM_ACC", checkPair("pm_gen", "pm_acc", "%.2f", " g/L"), value: nil)
                row("PM_ACC_DSD ÷ PM_GEN", checkRatioText, value: nil)
                Button("Stop", role: .destructive) { recorder.stopCheck() }
                    .font(.subheadline)
            } else {
                Button { recorder.startCheck() } label: {
                    Label(String(format: "Start the check (%.0f min)", Tuning.recordCheckDuration / 60),
                          systemImage: "speedometer")
                }
                .buttonStyle(.bordered)
                .disabled(!recorder.isRecording)
                if !recorder.checkNote.isEmpty {
                    Text(recorder.checkNote).font(.caption)
                }
            }
            Text(checkExplanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func checkValue(_ column: String) -> Double? {
        recorder.checkValues[column]
    }

    /// "129 / 109 kPa" from two of the check's values.
    private func checkPair(_ first: String, _ second: String, _ format: String, _ unit: String) -> String {
        let a = checkValue(first)
        let b = checkValue(second)
        guard a != nil || b != nil else { return "--" }
        return number(a, format) + " / " + number(b, format) + unit
    }

    private var checkEGTText: String {
        let temps = ["egt1_c", "egt2_c", "egt3_c"].compactMap { checkValue($0) }
        guard !temps.isEmpty else { return "--" }
        return temps.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " °C"
    }

    private var checkRatioText: String {
        guard let dsd = checkValue("pm_acc_dsd"), let generated = checkValue("pm_gen"), generated > 0.2 else {
            return "--"
        }
        return String(format: "%.1f×", dsd / generated)
    }

    /// "2.1 m³/min · 0.78 V": the PCM's exhaust flow (0430) and the DPF pressure sensor's voltage (03DB).
    private var checkFlowText: String {
        let flow = checkValue("exh_flow")
        let volts = checkValue("dpf_dp_sensor_v")
        guard flow != nil || volts != nil else { return "--" }
        return number(flow, "%.2f", " m³/min") + " · " + number(volts, "%.2f", " V")
    }

    /// "17.2 % · 6.4 mm³": exhaust O2 (0451) and the injection amount the PCM wants (1411).
    private var checkO2FuelText: String {
        let o2 = checkValue("exh_o2_pct")
        let fuel = checkValue("fuel_inj_dsd_mm3")
        guard o2 != nil || fuel != nil else { return "--" }
        return number(o2, "%.1f", " %") + " · " + number(fuel, "%.1f", " mm³")
    }

    private var checkExplanation: String {
        String(format: """
            Parked in P, engine warm (coolant above 80 °C), A/C off: tap Start, hold about 3,000 rpm for a \
            minute until the numbers settle, then let it idle. Everything is read back to back for %.0f min \
            (kind "check" in the export); it stops by itself if the car moves. Mazda's test for the DPF \
            pressure sensor (DTC P243C) compares PM_ACC_DSD with PM_GEN once they settle at 3,000 rpm: twice \
            or more points at the sensor. The back pressure, exhaust flow and air flow at 3,000 rpm are also a \
            baseline to repeat after the next regeneration (ash) and later on.
            """, Tuning.recordCheckDuration / 60)
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
                Text("Nothing yet. From now on every regeneration is recorded from start to end: the distance "
                     + "before it, soot before and after, peak temperatures, how long it took, and whether it "
                     + "completed or was interrupted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(log.entries.prefix(20)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: entry.outcome == .interrupted ? "xmark.circle" : "checkmark.circle")
                            .foregroundColor(entry.outcome == .interrupted ? .orange : .green)
                        Text(entry.date.formatted(.dateTime.day().month().hour().minute()))
                        Spacer()
                        Text(DPFRegenLog.describe(entry)).monospacedDigit()
                    }
                    if let details = DPFRegenLog.details(entry) {
                        Text(details).foregroundStyle(.secondary).monospacedDigit()
                    }
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

    /// Fuel in the oil and what leads to it (EngineHealth), before the PCM sets a code.
    private var engineHealthCard: some View {
        card("Engine health: before the warning light") {
            EngineHealthList(health: recorder.health)
        }
    }

    private var engineCard: some View {
        card("Engine, EGR and oil") {
            let r = monitor.reading
            row("EGR A (hot) target / actual", pair(r.egr?.commandedA, r.egr?.actualA, "%.0f", " %"), value: .egr)
            row("EGR B (cooled) target / actual", pair(r.egr?.commandedB, r.egr?.actualB, "%.0f", " %"), value: .egr)
            row("Intake shutter", number(r.intakeShutter, "%.0f", " %"), value: .intakeShutter)
            row("Boost target / actual", pair(r.boostTarget, r.boost, "%.0f", " kPa"), value: .boost)
            row("Air flow", number(r.airFlow, "%.1f", " g/s"), value: .airFlow)
            ForEach(r.chargeAirTemps.sorted { $0.key < $1.key }, id: \.key) { entry in
                row("Charge air \(entry.key)", String(format: "%.0f °C", entry.value), value: nil)
            }
            if r.chargeAirTemps.isEmpty { row("Charge air", "--", value: .chargeAir) }
            row("Oil temperature", number(r.oilTemp, "%.0f", " °C"), value: .oilTemp)
            row(MazdaDPF.Value.oilDilution.label, number(r.oilDilution, "%.0f", " g"), value: .oilDilution)
            row(MazdaDPF.Value.oilDilutionEvents.label, r.oilDilutionEvents.map { "\($0)" } ?? "--",
                value: .oilDilutionEvents)
            Text("EGR closes to 0 % during a regeneration. Fuel in the oil (220 3E1) is the PCM's own estimate "
                 + "(FORScan's scale, g): it goes up with every regeneration and down as the fuel boils off on long "
                 + "drives. Mazda sets P252F at 1,661 g; the Engine health card has the rest.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func pair(_ a: Double?, _ b: Double?, _ format: String, _ unit: String) -> String {
        guard a != nil || b != nil else { return "--" }
        return number(a, format) + " / " + number(b, format) + unit
    }

    private var rawCard: some View {
        card("Raw PCM replies") {
            ForEach(MazdaDPF.Value.allCases) { value in
                LabeledContent("\(MazdaDPF.header) 22\(value.did)") {
                    Text(rawText(value)).font(.system(.caption, design: .monospaced))
                }
                .font(.caption)
            }
            Text("The Mazda values (04xx, 0380, 03E1, DD01) and their scaling come from community PID lists "
                 + "for SkyActiv-D cars (Torque plugin, FORScan forum) and FORScan's PCM definitions, not Mazda "
                 + "documents. The F4xx ones are "
                 + "standard OBD2 PIDs. If a value looks off, compare it with FORScan; the raw bytes are here "
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
