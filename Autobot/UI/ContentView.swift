// ContentView.swift
// Root: the start screen (BootView) first; once it reaches 100 % it flies through the ring into
// the dashboard: connection status, live selector, lamp state, assistant
// status, packet log.

import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppModel()
    @State private var showDashboard = false

    var body: some View {
        ZStack {
            if showDashboard {
                DashboardView(app: app)
                    .transition(.dashboardReveal)
            } else {
                BootView(boot: app.boot, onIgnite: app.ignite)
                    .transition(.bootExit)
                    .zIndex(1)
            }
        }
        .onReceive(app.boot.$phase) { phase in
            guard phase == .finished, !showDashboard else { return }
            withAnimation(.timingCurve(0.65, 0, 0.25, 1, duration: AppConfig.Boot.dashboardTransition)) {
                showDashboard = true
            }
        }
        .onOpenURL { url in
            guard url.scheme == "autobot" else { return }
            switch url.host {
            case "start":
                app.startFromCarPlayAutomation()      // the dashboard follows once the checks pass
            case "maps":   // the QQ Music shortcut is done: Autobot opens Google Maps now
                app.assistant.musicShortcutReturned()
            default:
                break
            }
        }
    }
}

// MARK: - Boot → dashboard transition

/// The start screen zooms past the camera (as if driving through the ring) and fades out…
private struct BootExit: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + 1.6 * amount)
            .blur(radius: 10 * amount)
            .opacity(1 - amount)
    }
}

/// …while the dashboard settles in from slightly behind.
private struct DashboardReveal: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.08 * amount)
            .opacity(1 - amount)
    }
}

private extension AnyTransition {
    static var bootExit: AnyTransition {
        .modifier(active: BootExit(amount: 1), identity: BootExit(amount: 0))
    }

    static var dashboardReveal: AnyTransition {
        .modifier(active: DashboardReveal(amount: 1), identity: DashboardReveal(amount: 0))
    }
}

// MARK: - Dashboard

private struct DashboardView: View {
    @ObservedObject var app: AppModel
    @State private var showingPlaces = false

    var body: some View {
        VStack(spacing: 16) {
            ConnectionStatusView(lamp: app.lamp, carPlay: app.carPlay)
            DrivingView(obd: app.obd, speed: app.speed, manual: app.manual)
            MFinderButton(finder: app.mFinder, obd: app.obd, manual: app.manual)
            if AppConfig.DPF.enabled {
                DPFMonitorButton(monitor: app.dpf, log: app.dpfLog, finder: app.dpfHistory, recorder: app.dpfRecorder)
            }
            if AppConfig.OBD.selectorDiagnostics {
                SelectorDiagnosticsView(obd: app.obd)
            }
            LampStateView(lighting: app.lighting, lamp: app.lamp, powerMode: app.powerMode)
            if AppConfig.Doors.enabled {           // hidden while door detection is off
                DoorTestView(doors: app.doors, obd: app.obd)
                DoorFinderButton(finder: app.doorFinder, obd: app.obd)
            }
            AssistantView(assistant: app.assistant, onTest: app.testWelcome,
                          onTestCommute: app.testCommute)
            PowerModeTestView(powerMode: app.powerMode, onTest: app.testPowerMode)
            if AppConfig.Reverse.enabled {
                ReverseTestView(reverse: app.reverse, onTest: app.testReverse)
            }
            if AppConfig.TurnSignals.enabled {
                TurnSignalTestView(flash: app.turnSignals, obd: app.obd, onTest: app.testTurnSignal)
            }
            if AppConfig.Rain.enabled {
                RainModeView(rain: app.rain, finder: app.wiperFinder, obd: app.obd, onTest: app.testRain)
            }
            if AppConfig.Climate.enabled {        // hidden until there's an MS-CAN adapter
                ClimateTestView(climate: app.climate, obd: app.obd, onTest: app.testClimate)
            }
            SavedPlacesButton(store: app.places) { showingPlaces = true }
            PacketLogView(lamp: app.lamp)
        }
        .padding()
        .sheet(isPresented: $showingPlaces) {
            SavedPlacesView(store: app.places, backup: app.backup)
        }
    }
}

// MARK: - Sections

private struct ConnectionStatusView: View {
    @ObservedObject var lamp: LampController
    @ObservedObject var carPlay: CarPlayMonitor

    var body: some View {
        VStack(spacing: 4) {
            Text(lamp.status).font(.headline)
            Label(carPlay.isConnected ? "CarPlay connected" : "CarPlay not detected",
                  systemImage: carPlay.isConnected ? "car.fill" : "car")
                .font(.subheadline)
                .foregroundColor(carPlay.isConnected ? .green : .secondary)
        }
        .multilineTextAlignment(.center)
    }
}

/// The Power Mode trigger's main value in large type (AppConfig.PowerMode.trigger), the live data
/// below it and the OBD2 adapter's status.
private struct DrivingView: View {
    @ObservedObject var obd: OBDAdapter
    @ObservedObject var speed: SpeedMonitor
    @ObservedObject var manual: ManualShiftDetector

    private var gpsSpeedText: String { speed.speedKmh.map { String(format: "%.0f", $0) } ?? "--" }
    private var obdSpeedText: String { obd.sample?.speed.map { String(format: "%.0f", $0) } ?? "--" }

    var body: some View {
        VStack(spacing: 4) {
            switch AppConfig.PowerMode.trigger {
            case .manualShift:
                Text(manual.selector?.label ?? "--")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                Text(manual.state == .redBreathing ? "M · Power Mode on" : "Power Mode off")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if manual.selector == nil {
                    Text("Selector signal unavailable · use M finder if needed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text("GPS \(gpsSpeedText) km/h  ·  OBD \(obdSpeedText) km/h")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            case .speed:
                Text(gpsSpeedText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("km/h  ·  Power Mode at \(Int(AppConfig.Speed.powerModeThresholdKmh))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Location: \(speed.authorization)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(obd.status)
                .font(.caption)
                .foregroundColor(obd.isReady ? .green : .secondary)
        }
        .multilineTextAlignment(.center)
    }
}

private struct LampStateView: View {
    @ObservedObject var lighting: LightingArbiter
    @ObservedObject var lamp: LampController
    @ObservedObject var powerMode: PowerModeController

    var body: some View {
        VStack(spacing: 4) {
            if let active = lighting.active {
                HStack {
                    SceneIndicator(scene: active.scene)
                    Text(active.scene.label).font(.title3.bold())
                }
                if let target = powerMode.switchingTo {
                    Text("3-second buffer → \(target.label)")
                        .font(.subheadline.bold())
                        .foregroundColor(.red)
                }
                Text("By: \(active.source.label)  ·  "
                     + (lamp.appliedState == active.scene ? "Sent to lamp" : "Waiting for lamp…"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Coloured dot that mimics the lamp: steady, slowly breathing, or flashing.
private struct SceneIndicator: View {
    let scene: LampState

    var body: some View {
        TimelineView(.animation) { context in
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .opacity(opacity(at: context.date))
        }
    }

    private var color: Color {
        switch scene {
        case .purpleSteady: return Color(red: 0.5, green: 0, blue: 1)
        case .purpleBurstFlash: return Color(red: 0.5, green: 0, blue: 1)
        case .blueBurstFlash: return .blue
        case .yellowBreathing: return .yellow
        case .cyanBreathing: return .cyan
        case .redBreathing, .redBurstFlash: return .red
        }
    }

    private func opacity(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        switch scene {
        case .purpleSteady: return 1
        case .redBreathing, .yellowBreathing, .cyanBreathing:
            return 0.25 + 0.75 * (0.5 + 0.5 * sin(t * 2 * .pi / 2.5))                   // ~2.5 s breath
        case .redBurstFlash, .blueBurstFlash, .purpleBurstFlash: return Int(t * 8) % 2 == 0 ? 1 : 0.1   // fast flash
        }
    }
}

/// The doors and the boot: live from the car while the doors are read (the BCM's door status, or
/// doors the finder learned), otherwise test buttons (they still work as a test while live, until
/// the next reading).
private struct DoorTestView: View {
    @ObservedObject var doors: DoorMonitor
    @ObservedObject var obd: OBDAdapter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(obd.doorStates.isEmpty ? "Door test" : "Doors (live from the car)").font(.headline)
            HStack(spacing: 6) {
                ForEach(DoorMonitor.Opening.allCases) { opening in
                    let isOpen = doors.open.contains(opening)
                    Button(opening.rawValue) { doors.toggle(opening) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(isOpen ? Color.red : Color.gray)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AssistantView: View {
    @ObservedObject var assistant: WelcomeAssistant
    let onTest: () -> Void
    let onTestCommute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Assistant").font(.headline)
                Spacer()
                Button("Test commute", action: onTestCommute)
                    .font(.caption)
                    .buttonStyle(.bordered)
                Button("Test welcome", action: onTest)
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
            Text(assistant.status).font(.subheadline)
            if let heard = assistant.lastHeard {
                Text("Heard: \"\(heard)\"").font(.caption)
            }
            if let destination = assistant.lastDestination {
                Text("Destination: \(destination)").font(.caption.bold())
            }
            if let commute = assistant.lastCommuteCheck {
                Text(commute).font(.caption)
            }
            if let shortcut = assistant.lastShortcut {
                Text("Shortcut: \(shortcut)").font(.caption)
                    .textSelection(.enabled)
            }
            Text("Understanding: \(assistant.understandingEngine)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

/// Pretends the Power Mode trigger switched: 3-second flash, announcement, then new lighting.
private struct PowerModeTestView: View {
    @ObservedObject var powerMode: PowerModeController
    let onTest: (LampState) -> Void

    var body: some View {
        HStack {
            Text("Power Mode test").font(.headline)
            if powerMode.simulated != nil {
                Text("(simulated)").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button("Power ON") { onTest(.redBreathing) }
                .tint(.red)
            Button("Power OFF") { onTest(.purpleSteady) }
                .tint(Color(red: 0.5, green: 0, blue: 1))
        }
        .font(.caption)
        .buttonStyle(.bordered)
    }
}

/// Reverse (ReverseLight): yellow gradient breathing while the lever is in R. The button stands in for
/// the lever: tap = in R, tap again = back to the car's lever.
private struct ReverseTestView: View {
    @ObservedObject var reverse: ReverseLight
    let onTest: () -> Void

    var body: some View {
        HStack {
            Text("Reverse test").font(.headline)
            if reverse.isOn {
                Text(reverse.simulated ? "R (simulated)" : "R from the car")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("R") { onTest() }
                .tint(reverse.simulated ? .yellow : .gray)
        }
        .font(.caption)
        .buttonStyle(.bordered)
    }
}

/// Turn signals and hazard lights (TurnSignalFlash): current Power Mode colour flash while they flash.
/// The signal state comes from the indicator lamp frame on HS-CAN; the buttons stand in for the lever
/// and hazard switch (tap to start, tap again to stop).
private struct TurnSignalTestView: View {
    @ObservedObject var flash: TurnSignalFlash
    @ObservedObject var obd: OBDAdapter
    let onTest: (TurnSignals.State) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Turn signals").font(.headline)
                Spacer()
                Button("Left") { onTest(.left) }
                    .tint(buttonTint(.left))
                Button("Hazard") { onTest(.hazard) }
                    .tint(buttonTint(.hazard))
                Button("Right") { onTest(.right) }
                    .tint(buttonTint(.right))
            }
            .font(.caption)
            .buttonStyle(.bordered)
            Text(statusText)
                .font(.caption2)
                .foregroundColor(flash.state.isOn ? .orange : .secondary)
        }
    }

    private func buttonTint(_ side: TurnSignals.State) -> Color {
        flash.simulated == side ? .yellow : .gray
    }

    /// What the indicators do now, and where that comes from.
    private var statusText: String {
        let now = flash.state.isOn ? "\(flash.state.label) flashing → mode-coloured flash" : "Off"
        if flash.simulated != nil { return now + " (simulated)" }
        let frame = AppConfig.TurnSignals.frameID
        switch obd.hearsLightsFrame {
        case true?: return now + "  ·  from the car, \(frame): \(obd.lightsFrame.map { TurnSignals.hex($0) } ?? "--")"
        case false?: return now + "  ·  frame \(frame) not heard on the bus: test buttons only (see the log)"
        case nil: return now + "  ·  listened for once live data runs"
        }
    }
}

/// Rain mode (RainMode): cyan gradient breathing while it rains as far as the wipers say — LO / HI at
/// once, AUTO / INT once they really wipe. The lever comes from frame 09A, the wiping in AUTO / INT from
/// the front body control module; Rain stands in for both, Wiper finder finds this car's bits.
private struct RainModeView: View {
    @ObservedObject var rain: RainMode
    @ObservedObject var finder: WiperFinder
    @ObservedObject var obd: OBDAdapter
    let onTest: () -> Void
    @State private var showingFinder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Rain mode").font(.headline)
                Spacer()
                Button("Wiper finder") { showingFinder = true }
                Button("Rain") { onTest() }
                    .tint(rain.simulated ? .cyan : .gray)
            }
            .font(.caption)
            .buttonStyle(.bordered)
            Text(statusText)
                .font(.caption2)
                .foregroundColor(rain.isOn ? .cyan : .secondary)
        }
        .sheet(isPresented: $showingFinder) {
            WiperFinderView(finder: finder, rain: rain, obd: obd)
        }
    }

    /// Now, the lever (in AUTO / INT: the wiper motor), and where the bits come from.
    private var statusText: String {
        let now = rain.isOn ? "Raining → cyan breathing" : "Dry"
        if rain.simulated { return now + " (simulated)" }
        var parts = [now, "wipers " + (rain.confirmed?.label ?? "--") + (rain.washing ? " + washer" : "")]
        if rain.confirmed == .auto { parts.append(rain.autoStatus) }
        parts.append(finder.learnedLever != nil ? "lever bits checked" : "lever bits built in")
        if obd.hearsLightsFrame == false { parts.append("frame \(AppConfig.TurnSignals.frameID) not heard") }
        return parts.joined(separator: "  ·  ")
    }
}

/// Finds this car's wiper bits (WiperFinder): the lever check (frame 09A in each position) and the wiper
/// motor (front body control module: parked, wiping, then traces of one wipe).
private struct WiperFinderView: View {
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
                                   value: obd.lightsFrame.map { Wipers.hex($0) } ?? "--")
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

/// A/C temperature flash (ClimateTempFlash): a click of the dial colder → blue burst flash, warmer →
/// red, until 3 s after the last click. These buttons stand in for the dial while the car's set
/// temperature can't be read (the climate control unit is on MS-CAN, see README).
private struct ClimateTestView: View {
    @ObservedObject var climate: ClimateTempFlash
    @ObservedObject var obd: OBDAdapter
    let onTest: (ClimateTempFlash.Direction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("A/C temp test").font(.headline)
                if let setPoint = climate.setPoint {
                    Text(String(format: "%.1f °C", setPoint) + (climate.simulated ? " (simulated)" : ""))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("A/C −") { onTest(.colder) }
                    .tint(.blue)
                Button("A/C +") { onTest(.warmer) }
                    .tint(.red)
            }
            .font(.caption)
            .buttonStyle(.bordered)
            Text(unitText)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// Whether the car's set temperature could be read through this adapter.
    private var unitText: String {
        switch obd.reportsClimateUnit {
        case true?: return "Climate control unit answers: its set temperature can be looked for"
        case false?: return "Climate control unit not reachable (MS-CAN): test buttons only"
        case nil: return "Climate control unit: checked when the adapter connects"
        }
    }
}

private struct SavedPlacesButton: View {
    @ObservedObject var store: SavedPlacesStore
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Label("Saved places", systemImage: "mappin.and.ellipse")
                Spacer()
                Text("\(store.places.count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .font(.headline)
        }
        .buttonStyle(.plain)
    }
}

/// Dashboard row: whether the M flag has been learned; opens the M finder.
private struct MFinderButton: View {
    @ObservedObject var finder: MFinder
    @ObservedObject var obd: OBDAdapter
    @ObservedObject var manual: ManualShiftDetector
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack {
                Label("M finder", systemImage: "gearshape.2")
                Spacer()
                Text(finder.learned != nil ? "M flag learned" : "M flag built in")
                    .font(.subheadline)
                    .foregroundColor(.green)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .font(.headline)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            MFinderView(finder: finder, obd: obd, manual: manual)
        }
    }
}

/// Finds the "lever in M" flag on this car (MFinder): scan once, then snapshots in D and in M1.
private struct MFinderView: View {
    @ObservedObject var finder: MFinder
    @ObservedObject var obd: OBDAdapter
    @ObservedObject var manual: ManualShiftDetector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(finder.message)
                    if let progress {
                        ProgressView(value: progress.value) { Text(progress.label).font(.caption) }
                        Button("Cancel", role: .cancel) { finder.cancel() }
                    }
                }
                Section("Live from the car") {
                    LabeledContent("TCM gear code", value: tcmText)
                    LabeledContent("Lever", value: manual.selector?.label ?? "D or M (flag not known)")
                    LabeledContent("Gear", value: manual.gear.map { "\($0)" } ?? "--")
                }
                Section {
                    Button("Scan the car (once, 1–2 min)") { finder.scan() }
                        .disabled(finder.isBusy)
                    LabeledContent("DIDs answering", value: "\(finder.supported.count)")
                    Button("Snapshot D  ·  \(finder.dSnapshots) taken") { finder.snapshotD() }
                        .disabled(finder.isBusy || finder.supported.isEmpty)
                    Button("Snapshot M1  ·  \(finder.mSnapshots) taken") { finder.snapshotM() }
                        .disabled(finder.isBusy || finder.supported.isEmpty)
                    Button("Reset snapshots", role: .destructive) { finder.resetSnapshots() }
                        .disabled(finder.isBusy)
                } header: {
                    Text("Find the M flag")
                } footer: {
                    Text("Car stopped, engine running, foot on the brake. Scan once. Then alternate: "
                         + "lever in D → Snapshot D, lever in M (stay in M1, don't shift) → Snapshot M. "
                         + "After two of each the best candidate is used automatically.")
                }
                if !finder.candidates.isEmpty {
                    Section("Candidates, best first") {
                        ForEach(finder.candidates.prefix(8)) { candidate in
                            Text(candidate.signal.label(off: "D", on: "M") + "  ·  score \(candidate.score)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Section("In use for Power Mode") {
                    Text(finder.inUse.label(off: "D", on: "M") + (finder.learned == nil ? "  ·  built in" : "  ·  learned"))
                        .font(.system(.caption, design: .monospaced))
                    if finder.learned != nil {
                        Button("Forget (back to the built-in flag)", role: .destructive) { finder.forget() }
                            .disabled(finder.isBusy)
                    }
                }
            }
            .navigationTitle("M finder")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var progress: (value: Double, label: String)? {
        switch finder.phase {
        case .idle:
            return nil
        case .scanning(let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "Scanning \(done) / \(total)")
        case .snapshot(let position, let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "Snapshot \(position): \(done) / \(total)")
        }
    }

    private var tcmText: String {
        guard let code = obd.tcmGearCode else {
            return obd.reportsTCMGear == false ? "not answered" : "--"
        }
        let meaning: String
        switch MazdaTCM.range(gearCode: code) {
        case .park?: meaning = "P"
        case .reverse?: meaning = "R"
        case .neutral?: meaning = "N"
        case .forward(let gear)?: meaning = gear.map { "D/M, gear \($0)" } ?? "between gears"
        case nil: meaning = "unknown"
        }
        return String(format: "%02X", code) + "  →  " + meaning
    }
}

/// Dashboard row: how many doors are read from the car; opens the doors screen (live values and
/// the finder).
private struct DoorFinderButton: View {
    @ObservedObject var finder: DoorFinder
    @ObservedObject var obd: OBDAdapter
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack {
                Label("Doors", systemImage: "car.side")
                Spacer()
                Text(summary)
                    .font(.subheadline)
                    .foregroundColor(obd.doorSignals.isEmpty ? .secondary : .green)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .font(.headline)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            DoorFinderView(finder: finder, obd: obd)
        }
    }

    /// "5 of 5 from the car", or why not.
    private var summary: String {
        let total = DoorMonitor.Opening.allCases.count
        if !obd.doorSignals.isEmpty { return "\(obd.doorSignals.count) of \(total) from the car" }
        return obd.reportsDoors == nil ? "checked on connect" : "0 of \(total) (finder needed)"
    }
}

/// The doors live from the car, where they come from, and the finder (DoorFinder: scan once,
/// "All closed", then one opening at a time) for a door that isn't shown right.
private struct DoorFinderView: View {
    @ObservedObject var finder: DoorFinder
    @ObservedObject var obd: OBDAdapter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(finder.message)
                    if let progress {
                        ProgressView(value: progress.value) { Text(progress.label).font(.caption) }
                        Button("Cancel", role: .cancel) { finder.cancel() }
                    }
                }
                Section {
                    ForEach(DoorMonitor.Opening.allCases) { opening in
                        LabeledContent(opening.rawValue, value: liveText(opening))
                    }
                    ForEach(obd.doorRaw.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: obd.doorRaw[key] ?? "")
                            .font(.system(.caption, design: .monospaced))
                    }
                } header: {
                    Text("Live from the car")
                } footer: {
                    Text(sourceText)
                }
                Section {
                    Button("Scan the body control module (once, ~2 min)") { finder.scan() }
                        .disabled(finder.isBusy)
                    LabeledContent("DIDs answering", value: "\(finder.supported.count)")
                    snapshotButton(.allClosed)
                    ForEach(DoorMonitor.Opening.allCases) { opening in
                        snapshotButton(.open(opening))
                    }
                    Button("Reset snapshots", role: .destructive) { finder.resetSnapshots() }
                        .disabled(finder.isBusy)
                } header: {
                    Text("Find the door switches")
                } footer: {
                    Text("Only needed if a door isn't shown right above. Parked, ignition on. Scan once. "
                         + "Then: everything shut → All closed. For each opening: open only that one → its "
                         + "button → close it. Finish with All closed again. A door found this way "
                         + "replaces the built-in one as soon as it's certain.")
                }
                Section("In use") {
                    ForEach(DoorMonitor.Opening.allCases) { opening in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opening.rawValue).font(.subheadline.bold())
                            Text(inUseText(opening))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(obd.doorSignals[opening] == nil ? .secondary : .primary)
                            if finder.learned[opening] == nil, let candidate = finder.best[opening] {
                                Text("finder: maybe " + candidate.signal.label(off: "closed", on: "open")
                                     + " (needs more snapshots)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    if !finder.learned.isEmpty {
                        Button("Forget learned doors", role: .destructive) { finder.forget() }
                            .disabled(finder.isBusy)
                    }
                }
                Section {
                    if let url = exportURL {
                        ShareLink("Export raw scan (send to me)", item: url)
                    } else {
                        Text("Export raw scan — take some snapshots first")
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("If a door can't be found automatically, export the raw scan after one full "
                         + "pass (All closed, each door once, All closed) and share the file, so the "
                         + "exact door bits can be set by hand.")
                }
            }
            .navigationTitle("Doors")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var exportURL: URL? {
        _ = finder.counts        // recompute when a new snapshot arrives
        return finder.exportFile()
    }

    private func snapshotButton(_ scene: DoorFinder.Scene) -> some View {
        Button("\(scene.label)  ·  \(finder.counts[scene] ?? 0) taken") { finder.snapshot(scene) }
            .disabled(finder.isBusy || finder.supported.isEmpty)
    }

    private func liveText(_ opening: DoorMonitor.Opening) -> String {
        guard obd.doorSignals[opening] != nil else { return "not known" }
        guard let isOpen = obd.doorStates[opening] else { return "--" }
        return isOpen ? "OPEN" : "closed"
    }

    /// The signal read for this door, and where it comes from.
    private func inUseText(_ opening: DoorMonitor.Opening) -> String {
        guard let signal = obd.doorSignals[opening] else { return "—" }
        return signal.label(off: "closed", on: "open")
            + (finder.learned[opening] == nil ? "  ·  built in" : "  ·  learned")
    }

    /// Where the doors come from, under the live values.
    private var sourceText: String {
        switch obd.reportsDoors {
        case true?:
            return "From the body control module's door status (726 22C150, built in). Open each door "
                + "once to check; the finder below is only needed if one shows wrong."
        case false?:
            return "This car's body control module didn't answer the door status (726 22C150, see the "
                + "log), so doors can only come from the finder below."
        case nil:
            return "Checked when the adapter connects with the ignition on."
        }
    }

    private var progress: (value: Double, label: String)? {
        switch finder.phase {
        case .idle:
            return nil
        case .scanning(let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "Scanning \(done) / \(total)")
        case .snapshot(let label, let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "\(label): \(done) / \(total)")
        }
    }
}

/// On-car finder for the real M/D signal: raw bytes of each candidate transmission value on both
/// ECUs, live. Move the lever M <-> D and watch which row changes. Off via AppConfig.OBD.selectorDiagnostics.
private struct SelectorDiagnosticsView: View {
    @ObservedObject var obd: OBDAdapter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Selector diagnostics — move lever M↔D, watch for a change")
                .font(.caption.bold())
            ForEach(obd.selectorDiag) { row in
                Text("\(row.id)  →  \(row.raw)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(row.changed ? .red : (row.raw == "—" ? .secondary : .primary))
            }
            if obd.selectorDiag.isEmpty {
                Text("waiting for the engine ECU…").font(.caption2).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

private struct PacketLogView: View {
    @ObservedObject var lamp: LampController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lamp.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
