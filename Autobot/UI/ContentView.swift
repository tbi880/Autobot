// ContentView.swift
// Root: the start screen (BootView) first; once it reaches 100 % it flies through the ring into
// the dashboard: connection status, live data (RPM, gear, manual shifting), lamp state, assistant
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
            if AppConfig.Rain.enabled {
                RainTestView(rain: app.rain, finder: app.wiperFinder, obd: app.obd, onTest: app.testRain)
            }
            if AppConfig.TurnSignals.enabled {
                TurnSignalTestView(flash: app.turnSignals, obd: app.obd, onTest: app.testTurnSignal)
            }
            if AppConfig.IStop.enabled {
                IStopView(controller: app.iStop, finder: app.iStopFinder, obd: app.obd)
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

    private var rpmText: String { obd.rpm.map { String(format: "%.0f", $0) } ?? "--" }
    private var gpsSpeedText: String { speed.speedKmh.map { String(format: "%.0f", $0) } ?? "--" }
    private var obdSpeedText: String { obd.sample?.speed.map { String(format: "%.0f", $0) } ?? "--" }
    private var gearText: String {
        if let lever = manual.selector, lever != .drive, lever != .manual { return lever.label }   // P, R, N
        guard let gear = manual.gear else { return "gear --" }
        let prefix = manual.selector == .manual ? "M" : (manual.selector == .drive ? "D" : "gear ")
        return prefix + "\(gear)" + (manual.gearFromCar ? "" : " (est.)")
    }
    private var demandText: String {
        let label = obd.demandSource?.hasPrefix("engine load") == true ? "load" : "pedal"
        return label + " " + (obd.sample?.demand.map { String(format: "%.0f %%", $0) } ?? "--")
    }

    var body: some View {
        VStack(spacing: 4) {
            switch AppConfig.PowerMode.trigger {
            case .manualShift:
                Text(rpmText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("r/min  ·  \(gearText)  ·  \(obdSpeedText) km/h  ·  \(demandText)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if manual.state == .redBreathing {
                    Text("Manual: \(manual.reason ?? "shifting by hand")")
                        .font(.subheadline.bold())
                        .foregroundColor(.red)
                } else {
                    Text(manual.usingRealSelector ? "Selector in \(manual.selector?.label ?? "D")" : "Driving in D")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if manual.usingRealSelector {
                    Text("Lever \(manual.selector?.label ?? "--") from the car  ·  GPS \(gpsSpeedText) km/h")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Selector estimated · top gear " + String(format: "%.1f", manual.topGearRatio)
                         + " r/min per km/h  ·  GPS \(gpsSpeedText) km/h")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            case .engineRPM:
                Text(rpmText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("r/min  ·  Power Mode at \(Int(AppConfig.Engine.powerModeThresholdRpm))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("GPS \(gpsSpeedText) km/h  ·  Location: \(speed.authorization)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .speed:
                Text(gpsSpeedText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("km/h  ·  Power Mode at \(Int(AppConfig.Speed.powerModeThresholdKmh))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Engine \(rpmText) r/min  ·  Location: \(speed.authorization)")
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
                    Text("Buffer zone → \(target.label)")
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
        case .blueBurstFlash: return .blue
        case .yellowBurstFlash, .yellowBreathing: return .yellow
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
        case .redBurstFlash, .blueBurstFlash, .yellowBurstFlash: return Int(t * 8) % 2 == 0 ? 1 : 0.1   // fast flash
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

/// Pretends the Power Mode trigger switched: buffer zone flash, announcement, then the new lighting.
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

/// Rain mode (RainMode): cyan gradient breathing while the wipers are on (not for the washer). The lever
/// comes from the lights frame on HS-CAN, and in AUTO whether they really wipe from the front body control
/// module; Rain stands in for both, Wiper finder learns this car's bits.
private struct RainTestView: View {
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

    /// Now, the lever (in AUTO: whether they wipe), and where the bits come from.
    private var statusText: String {
        let now = rain.isOn ? "Raining → cyan breathing" : "Dry"
        if rain.simulated { return now + " (simulated)" }
        var parts = [now, "wipers " + (rain.lever?.label ?? "--") + (rain.washing ? " + washer" : "")]
        if rain.lever == .auto {
            parts.append(finder.learnedMotor.isEmpty ? "motor not learned: AUTO doesn't count"
                         : rain.wipingInAuto ? "wiping" : "waiting for the rain sensor")
        }
        parts.append(finder.learned != nil ? "learned bits" : "built-in guess: Wiper finder learns them")
        return parts.joined(separator: "  ·  ")
    }
}

/// Learns this car's wiper bits (WiperFinder): the lights frame in each lever position, compared with OFF,
/// and the front body control module's DIDs with the wipers parked and wiping (for AUTO).
private struct WiperFinderView: View {
    @ObservedObject var finder: WiperFinder
    @ObservedObject var rain: RainMode
    @ObservedObject var obd: OBDAdapter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(finder.message)
                    if let progress {
                        if let value = progress.value {
                            ProgressView(value: value) { Text(progress.label).font(.caption) }
                        } else {
                            ProgressView { Text(progress.label).font(.caption) }
                        }
                        Button("Cancel", role: .cancel) { finder.cancel() }
                    }
                }
                Section("Live from the car") {
                    LabeledContent("Frame \(AppConfig.TurnSignals.frameID)",
                                   value: obd.lightsFrame.map { TurnSignals.hex($0) } ?? "--")
                        .font(.system(.caption, design: .monospaced))
                    LabeledContent("Wiper lever", value: (rain.lever?.label ?? "--") + (rain.washing ? " + washer" : ""))
                    LabeledContent("Wiper motor", value: motorText)
                    LabeledContent("Rain mode", value: rain.isOn ? "on" : "off")
                }
                Section {
                    Button("Scan the front body control module (once, a few min)") { finder.scan() }
                        .disabled(finder.isBusy || !obd.isReady)
                    LabeledContent("FBCM DIDs answering",
                                   value: finder.scanned ? "\(finder.motorDIDs.count)" : "not scanned")
                    ForEach(WiperSignal.Position.allCases) { position in
                        Button("\(position.label)  ·  \(finder.counts[position] ?? 0) taken") {
                            finder.snapshot(position)
                        }
                        .disabled(finder.isBusy || !obd.isReady)
                    }
                    Button("Reset snapshots", role: .destructive) { finder.resetSnapshots() }
                        .disabled(finder.isBusy)
                } header: {
                    Text("Find the wiper bits")
                } footer: {
                    Text("Parked, engine running. Scan once. Then hold the lever in each position and tap it: "
                         + "OFF → AUTO on dry glass → LO → HI (a quick spray first, so the blades don't run "
                         + "on dry glass) → Washer: lever OFF, pull it towards you and keep holding until "
                         + "it's done → OFF again once the wipers have parked. Then Use it. Without the scan "
                         + "only the lever is learned, and AUTO doesn't count as rain.")
                }
                if finder.candidate != nil || !finder.motorCandidates.isEmpty {
                    Section("Found") {
                        ForEach(finder.candidate?.descriptions ?? [], id: \.self) { line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                        ForEach(motorLines(finder.motorCandidates), id: \.self) { line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                        notesList
                        Button("Use it for rain mode") { finder.use() }
                            .disabled(finder.isBusy)
                    }
                } else if !finder.notes.isEmpty {
                    Section("Notes") { notesList }
                }
                Section("In use for rain mode") {
                    ForEach(finder.inUse.descriptions, id: \.self) { line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                    Text(finder.learned != nil ? "lever: learned on this car"
                         : "lever: built-in guess (openpilot, CX-5 2017+)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(motorLines(finder.learnedMotor), id: \.self) { line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                    Text(finder.learnedMotor.isEmpty ? "wiper motor: not learned, AUTO doesn't count as rain"
                         : "wiper motor: learned, read while the lever is in AUTO")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if finder.learned != nil || !finder.learnedMotor.isEmpty {
                        Button("Forget (back to the built-in guess)", role: .destructive) { finder.forget() }
                            .disabled(finder.isBusy)
                    }
                }
                Section {
                    if let url = finder.exportURL {
                        ShareLink("Export raw scan (send to me)", item: url)
                    } else {
                        Text("Export raw scan — take some snapshots first")
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("If the wiper motor isn't found, export the raw scan after one full pass and share "
                         + "the file, so the bits can be set by hand.")
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

    private var notesList: some View {
        ForEach(finder.notes, id: \.self) { note in
            Text(note).font(.caption2).foregroundColor(.orange)
        }
    }

    private func motorLines(_ signals: [BitSignal]) -> [String] {
        signals.map { "Wiping: " + $0.label(off: "parked", on: "wiping") }
    }

    /// The wiper motor as read now (only while the lever is in AUTO).
    private var motorText: String {
        if finder.learnedMotor.isEmpty { return "not learned" }
        switch obd.wiperMotorRunning {
        case true?: return "wiping"
        case false?: return "parked"
        case nil: return rain.lever == .auto ? "--" : "read in AUTO only"
        }
    }

    private var progress: (value: Double?, label: String)? {
        switch finder.phase {
        case .idle:
            return nil
        case .scanning(let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "Scanning \(done) / \(total)")
        case .listening(let label):
            return (nil, "\(label): listening to the lever…")
        case .reading(let label, let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "\(label): FBCM \(done) / \(total)")
        }
    }
}

/// Turn signals and hazard lights (TurnSignalFlash): yellow burst flash while they flash. From the car
/// (the indicator lamp frame on HS-CAN); the buttons stand in for the lever and the hazard switch: tap
/// to start, tap again to stop.
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
        let now = flash.state.isOn ? "\(flash.state.label) flashing → yellow flash" : "Off"
        if flash.simulated != nil { return now + " (simulated)" }
        let frame = AppConfig.TurnSignals.frameID
        switch obd.hearsLightsFrame {
        case true?: return now + "  ·  from the car, \(frame): \(obd.lightsFrame.map { TurnSignals.hex($0) } ?? "--")"
        case false?: return now + "  ·  frame \(frame) not heard on the bus: test buttons only (see the log)"
        case nil: return now + "  ·  listened for once live data runs"
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

/// i-stop (idling stop) auto-off (IStopController): replays the OFF button at the start of a drive so
/// i-stop is off without pressing it. "Test off" presses now; "i-stop finder" learns this car's bits.
private struct IStopView: View {
    @ObservedObject var controller: IStopController
    @ObservedObject var finder: IStopFinder
    @ObservedObject var obd: OBDAdapter
    @State private var showingFinder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("i-stop").font(.headline)
                Spacer()
                Button("i-stop finder") { showingFinder = true }
                Button("Test off") { controller.test() }
                    .tint(.indigo)
                    .disabled(controller.busy || finder.learnedFrame == nil || !obd.isReady)
            }
            .font(.caption)
            .buttonStyle(.bordered)
            Text(statusText)
                .font(.caption2)
                .foregroundColor(obd.iStopOff == true ? .green : .secondary)
        }
        .sheet(isPresented: $showingFinder) {
            IStopFinderView(finder: finder, controller: controller, obd: obd)
        }
    }

    /// i-stop now, whether the button is learned, and what the last press did.
    private var statusText: String {
        var parts: [String] = []
        switch obd.iStopOff {
        case true?: parts.append("now off")
        case false?: parts.append("now on")
        case nil: parts.append(finder.learnedState == nil ? "state not learned" : "state --")
        }
        parts.append(finder.learnedFrame == nil ? "OFF button not learned: open the i-stop finder"
                     : "auto-off at the start of each drive")
        if let action = controller.lastAction { parts.append(action) }
        return parts.joined(separator: "  ·  ")
    }
}

/// Learns this car's i-stop bits (IStopFinder): the PCM state flag (i-stop on vs off, read-only) and
/// the OFF-button frame on the bus (released vs held, experimental — see the README).
private struct IStopFinderView: View {
    @ObservedObject var finder: IStopFinder
    @ObservedObject var controller: IStopController
    @ObservedObject var obd: OBDAdapter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(finder.message)
                    if let progress {
                        if let value = progress.value {
                            ProgressView(value: value) { Text(progress.label).font(.caption) }
                        } else {
                            ProgressView { Text(progress.label).font(.caption) }
                        }
                        Button("Cancel", role: .cancel) { finder.cancel() }
                    }
                }
                Section("Live from the car") {
                    LabeledContent("i-stop now", value: stateText)
                    Button("Press OFF now") { controller.test() }
                        .disabled(controller.busy || finder.learnedFrame == nil || !obd.isReady)
                }
                Section {
                    Button("Scan the PCM (once, 1–2 min)") { finder.scan() }
                        .disabled(finder.isBusy || !obd.isReady)
                    LabeledContent("PCM DIDs answering",
                                   value: finder.supported.isEmpty ? "not scanned" : "\(finder.supported.count)")
                    Button("Snapshot i-stop OFF  ·  \(finder.offSnapshots) taken") { finder.snapshotState(off: true) }
                        .disabled(finder.isBusy || finder.supported.isEmpty)
                    Button("Snapshot i-stop ON  ·  \(finder.onSnapshots) taken") { finder.snapshotState(off: false) }
                        .disabled(finder.isBusy || finder.supported.isEmpty)
                } header: {
                    Text("1 · Find the i-stop state (read-only)")
                } footer: {
                    Text("Parked, engine running. Scan once. Press the real OFF button so i-stop shows OFF → "
                         + "Snapshot i-stop OFF; press again so it shows ON → Snapshot i-stop ON. Repeat once. "
                         + "This is what lets auto-off confirm it worked.")
                }
                if !finder.stateCandidates.isEmpty {
                    Section("State candidates, best first") {
                        ForEach(finder.stateCandidates.prefix(6)) { candidate in
                            Text(candidate.signal.label(off: "on", on: "off") + "  ·  score \(candidate.score)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Section {
                    Button("Capture bus · nothing pressed  ·  \(finder.idleCaptures)") { finder.captureBus(pressed: false) }
                        .disabled(finder.isBusy || !obd.isReady)
                    Button("Capture bus · OFF button held  ·  \(finder.pressedCaptures)") { finder.captureBus(pressed: true) }
                        .disabled(finder.isBusy || !obd.isReady)
                } header: {
                    Text("2 · Find the OFF button (experimental)")
                } footer: {
                    Text("Capture with nothing pressed, then press and HOLD the OFF button for the whole 2 s and "
                         + "capture again. Twice each, then Use it. If no frame is found, the button may not be on "
                         + "the bus on this car — use FORScan coding instead (see the README).")
                }
                if !finder.frameCandidates.isEmpty {
                    Section("Button candidates, best first") {
                        ForEach(finder.frameCandidates.prefix(6)) { candidate in
                            Text(candidate.frame.label() + "  ·  score \(candidate.score)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Section {
                    Button("Use what was found") { finder.use() }
                        .disabled(finder.isBusy)
                    Button("Reset snapshots & captures", role: .destructive) { finder.resetWork() }
                        .disabled(finder.isBusy)
                }
                Section("In use") {
                    LabeledContent("State",
                                   value: finder.learnedState.map { $0.label(off: "on", on: "off") } ?? "not learned")
                        .font(.system(.caption, design: .monospaced))
                    LabeledContent("OFF button", value: finder.learnedFrame.map { $0.label() } ?? "not learned")
                        .font(.system(.caption, design: .monospaced))
                    if finder.learnedState != nil || finder.learnedFrame != nil {
                        Button("Forget (state and button)", role: .destructive) { finder.forget() }
                            .disabled(finder.isBusy)
                    }
                }
                Section {
                    if let url = finder.exportURL {
                        ShareLink("Export raw bus capture (send to me)", item: url)
                    } else {
                        Text("Export raw bus capture — take some captures first").foregroundColor(.secondary)
                    }
                } footer: {
                    Text("If the OFF button can't be found automatically, export the raw captures after a full "
                         + "pass and share the file, so the frame can be worked out by hand.")
                }
            }
            .navigationTitle("i-stop finder")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var stateText: String {
        switch obd.iStopOff {
        case true?: return "OFF (disabled)"
        case false?: return "ON (armed)"
        case nil: return finder.learnedState == nil ? "state not learned" : "--"
        }
    }

    private var progress: (value: Double?, label: String)? {
        switch finder.phase {
        case .idle:
            return nil
        case .scanning(let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "Scanning \(done) / \(total)")
        case .snapshot(let label, let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "\(label): \(done) / \(total)")
        case .capturing(let label):
            return (nil, "Capturing (\(label))…")
        }
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
