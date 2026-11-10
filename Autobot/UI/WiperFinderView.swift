// WiperFinderView.swift
// The wiper finder's screen, opened from the dashboard's Rain mode row: the lever check and the search
// for the wiper motor bit (WiperFinder), with what the car reports live.

import SwiftUI

/// Finds this car's wiper bits (WiperFinder): the lever check (frame 09A in each position) and the wiper
/// motor (front body control module: parked, wiping, then traces of one wipe).
struct WiperFinderView: View {
    @ObservedObject var finder: WiperFinder
    @ObservedObject var rain: RainMode
    @ObservedObject var obd: OBDAdapter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    if !finder.message.isEmpty {
                        Text(finder.message)
                    }
                    if let progress {
                        if let value = progress.value {
                            ProgressView(value: value) { Text(progress.label).font(.caption) }
                        } else {
                            ProgressView { Text(progress.label).font(.caption) }
                        }
                        Button("Cancel", role: .cancel) { finder.cancel() }
                    }
                    if let until = traceEnds {
                        TimelineView(.periodic(from: .now, by: 0.25)) { context in
                            Text("NOW: lever → AUTO / INT and hold it · "
                                 + "\(max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))) s")
                                .font(.headline)
                                .foregroundColor(.orange)
                        }
                    }
                }
                Section("Live from the car") {
                    LabeledContent("Frame \(AppConfig.TurnSignals.frameID)",
                                   value: obd.lightsFrame.map { $0.hexString() } ?? "--")
                        .font(.system(.caption, design: .monospaced))
                    LabeledContent("Lever bits (\(finder.leverInUse.placeLabel))",
                                   value: obd.lightsFrame.map { finder.leverInUse.codeText($0) } ?? "--")
                        .font(.system(.caption, design: .monospaced))
                    LabeledContent("Wiper lever", value: (rain.lever?.label ?? "--") + (rain.washing ? " + washer" : ""))
                    LabeledContent("Wiper motor", value: motorText)
                    LabeledContent("Rain mode", value: rain.isOn ? "on" : "off")
                }
                leverSection
                motorSection
                Section {
                    if let url = finder.exportURL {
                        ShareLink("Export raw data (send to me)", item: url)
                    } else {
                        Text("Export raw data — take some steps first")
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("Every frame, snapshot and trace taken so far, as a JSON file, so the bits can be set by "
                         + "hand if the finder can't.")
                }
            }
            .navigationTitle("Wiper finder")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var leverSection: some View {
        Section {
            Text(finder.leverHint).font(.caption)
            ForEach(WiperLeverLayout.Step.allCases) { step in
                Button("\(step.label)  ·  \(finder.leverTakes[step] ?? 0) taken") { finder.checkLever(step) }
                    .disabled(finder.isBusy || !obd.isReady)
            }
            if let layout = finder.leverResult.layout {
                ForEach(layout.descriptions, id: \.self) { line in
                    Text(line).font(.system(.caption, design: .monospaced))
                }
                Text(finder.leverResult.matchesBuiltIn ? "Same as the built-in layout." : "Not the built-in layout.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button("Use it for rain mode") { finder.useLever() }
                    .disabled(finder.isBusy || finder.learnedLever == layout)
            }
            notes(finder.leverResult.notes)
            if !finder.leverTakes.isEmpty {
                Button("Reset lever takes", role: .destructive) { finder.resetLever() }
                    .disabled(finder.isBusy)
            }
            ForEach(finder.leverInUse.descriptions, id: \.self) { line in
                Text("In use: " + line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if finder.learnedLever != nil {
                Button("Forget (back to the built-in layout)", role: .destructive) { finder.forgetLever() }
                    .disabled(finder.isBusy)
            }
        } header: {
            Text("1 · Lever (frame 09A)")
        } footer: {
            Text("Parked, engine running; each tap listens to the frame for 1.5 s, nothing else is read. Until "
                 + "it's saved: byte 4, 02 = LO contact, 04 = INT contact (AUTO / INT 04, LO 02, HI 06).")
        }
    }

    private var motorSection: some View {
        Section {
            Text(finder.motorHint).font(.caption)
            Button("Scan the front body control module (once, a few min)") { finder.scan() }
                .disabled(finder.isBusy || !obd.isReady)
            LabeledContent("FBCM DIDs answering", value: finder.scanned ? "\(finder.motorDIDs.count)" : "not scanned")
            Button("Parked (lever OFF)  ·  \(finder.parkedCount) taken") { finder.snapshotParked() }
                .disabled(finder.isBusy || !obd.isReady || !finder.scanned)
            Button("Wiping (lever LO)  ·  \(finder.wipingCount) taken") { finder.snapshotWiping() }
                .disabled(finder.isBusy || !obd.isReady || !finder.scanned)
            LabeledContent("Differ parked / wiping", value: candidatesText)
            Button("Trace a wipe (OFF → AUTO)  ·  \(finder.traceCount) taken") { finder.traceWipe() }
                .disabled(finder.isBusy || !obd.isReady || finder.candidates.isEmpty)
            if let signal = finder.motorResult.signal {
                Text("Wiping: " + signal.label).font(.system(.caption, design: .monospaced))
                if !finder.motorResult.alternatives.isEmpty {
                    Text("The same in " + finder.motorResult.alternatives.joined(separator: ", ") + " (not needed)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button("Use it for rain mode") { finder.useMotor() }
                    .disabled(finder.isBusy || finder.learnedMotor == signal)
            }
            notes(finder.motorResult.notes)
            if finder.parkedCount + finder.wipingCount + finder.traceCount > 0 {
                Button("Reset motor snapshots and traces", role: .destructive) { finder.resetMotor() }
                    .disabled(finder.isBusy)
            }
            Text(finder.learnedMotor.map { "In use: wiping = " + $0.label } ?? "In use: none, AUTO / INT doesn't count")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
            if finder.learnedMotor != nil {
                Button("Forget the motor bit", role: .destructive) { finder.forgetMotor() }
                    .disabled(finder.isBusy)
            }
        } header: {
            Text("2 · Wiper motor (FBCM 726, for AUTO / INT)")
        } footer: {
            Text("Parked, engine running. Scan once, then Parked, then Wiping (a quick spray first so the blades "
                 + "don't run dry), then Trace twice: lever OFF and wipers parked, tap Trace, and as soon as it says "
                 + "NOW move the lever to AUTO and hold it there until the trace ends. Only bits that come and go "
                 + "with that one wipe are kept, so there's one answer.")
        }
    }

    private func notes(_ lines: [String]) -> some View {
        ForEach(lines, id: \.self) { line in
            Text(line).font(.caption2).foregroundColor(.orange)
        }
    }

    private var candidatesText: String {
        guard finder.parkedCount > 0, finder.wipingCount > 0 else { return "--" }
        let dids = Set(finder.candidates.map(\.key)).count
        return "\(finder.candidates.count) bits in \(dids) DIDs"
    }

    /// When the running trace ends; nil while none runs.
    private var traceEnds: Date? {
        if case .tracing(let until) = finder.phase { return until }
        return nil
    }

    /// The wiper motor as read now (only while the lever is in AUTO / INT).
    private var motorText: String {
        guard finder.learnedMotor != nil else { return "not found yet" }
        if rain.motorPaused { return "not read in M / R" }
        switch obd.wiperMotorRunning {
        case true?: return "wiping"
        case false?: return "parked"
        case nil: return rain.confirmed == .auto ? "--" : "read in AUTO / INT only"
        }
    }

    private var progress: (value: Double?, label: String)? {
        switch finder.phase {
        case .idle:
            return nil
        case .listening(let label):
            return (nil, "\(label): listening to frame \(AppConfig.TurnSignals.frameID)…")
        case .scanning(let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "Scanning \(done) / \(total)")
        case .reading(let label, let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "\(label): FBCM \(done) / \(total)")
        case .waitingForTrace:
            return (nil, "Trace: waiting for the end of the live-data round…")
        case .tracing:
            return (nil, "Tracing the FBCM…")
        }
    }
}
