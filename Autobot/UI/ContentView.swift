// ContentView.swift
// Root: the start screen (BootView) first; once it reaches 100 % it flies through the ring into
// the dashboard. Its first screenful is the connection status, live selector and lamp state, the big
// microphone button (starts the Welcome) and the DPF monitor / Saved places rows; the finders, the test
// buttons and the packet log follow below it (scroll).
// Saved places opens from the start screen too, so the list can be edited without ENGINE START; so does
// the recorder's data export (DPFExporter).

import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppModel()
    @State private var showDashboard = false
    @State private var showingPlaces = false      // from the start screen or the dashboard
    @State private var showingExport = false      // the start screen's Export data: how far back?

    var body: some View {
        ZStack {
            if showDashboard {
                DashboardView(app: app, onShowPlaces: { showingPlaces = true })
                    .transition(.dashboardReveal)
            } else {
                BootView(boot: app.boot, places: app.places,
                         exporter: AppConfig.DPF.enabled ? app.startExport : nil, onIgnite: app.ignite,
                         onShowPlaces: { showingPlaces = true }, onExport: { showingExport = true })
                    .transition(.bootExit)
                    .zIndex(1)
            }
        }
        .sheet(isPresented: $showingPlaces) {
            SavedPlacesView(store: app.places, backup: app.backup)
        }
        .startScreenExport(app.startExport, isPresented: $showingExport)
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

/// Where the microphone button sits. It only depends on the screen, so the button never moves while
/// the lines above it come and go.
private struct DashboardLayout {
    let micDiameter: CGFloat
    /// Room for the status block above the button.
    let topHeight: CGFloat
    /// The first screenful (status, microphone, DPF monitor / Saved places); the rest follows below it.
    let heroHeight: CGFloat

    init(size: CGSize) {
        // The start screen's gauge (BootView): ENGINE START's face is 0.72 of it, this is a size up.
        let gauge = min((size.width - 40) / 1.2, size.height * 0.5, 340)
        micDiameter = max(gauge * 0.84, 160)
        // Centred a little below the middle of the screen (lower on a short screen, to clear the status block).
        topHeight = max(size.height * 0.58 - micDiameter / 2, 290)
        heroHeight = max(size.height, topHeight + micDiameter + 170)
    }
}

private struct DashboardView: View {
    @ObservedObject var app: AppModel
    let onShowPlaces: () -> Void

    var body: some View {
        GeometryReader { geo in
            let layout = DashboardLayout(size: geo.size)
            ScrollView {
                VStack(spacing: 16) {
                    hero(layout)
                    details
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }

    /// The first screenful: what the car is doing, the microphone button, and the two rows used most.
    private func hero(_ layout: DashboardLayout) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ConnectionStatusView(lamp: app.lamp, carPlay: app.carPlay)
                DrivingView(obd: app.obd, speed: app.speed, manual: app.manual)
                LampStateView(lighting: app.lighting, lamp: app.lamp, powerMode: app.powerMode)
            }
            .padding(.top, 12)
            .frame(height: layout.topHeight, alignment: .top)

            WelcomeMicButton(assistant: app.assistant, diameter: layout.micDiameter, action: app.testWelcome)

            AssistantStatusView(assistant: app.assistant)
                .padding(.top, 12)

            Spacer(minLength: 12)

            VStack(spacing: 16) {
                if AppConfig.DPF.enabled {
                    DPFMonitorButton(monitor: app.dpf, log: app.dpfLog, finder: app.dpfHistory,
                                     recorder: app.dpfRecorder)
                }
                SavedPlacesButton(store: app.places, onTap: onShowPlaces)
                Image(systemName: "chevron.compact.down")      // more below
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: layout.heroHeight)
    }

    /// Below the first screenful: assistant diagnostics, the finders, the test buttons and the log.
    private var details: some View {
        VStack(spacing: 16) {
            AssistantDiagnosticsView(assistant: app.assistant)
            MFinderButton(finder: app.mFinder, obd: app.obd, manual: app.manual)
            if AppConfig.OBD.selectorDiagnostics {
                SelectorDiagnosticsView(obd: app.obd)
            }
            if AppConfig.Doors.enabled {           // hidden while door detection is off
                DoorTestView(doors: app.doors, obd: app.obd)
                DoorFinderButton(finder: app.doorFinder, obd: app.obd)
            }
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
            PacketLogView(lamp: app.lamp)
                .frame(height: 280)
        }
    }
}

// MARK: - Microphone button

/// Starts the Welcome (greeting, "Where is our destination today?", Google Maps and music) by hand.
/// Larger than ENGINE START so it's easy to hit in the car. Pulses while a Welcome runs, and ignores
/// taps until that one has finished.
private struct WelcomeMicButton: View {
    @ObservedObject var assistant: WelcomeAssistant
    let diameter: CGFloat
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            MicButtonFace(diameter: diameter, active: assistant.isRunning)
        }
        .buttonStyle(MicButtonStyle())
        .disabled(assistant.isRunning)
        .sensoryFeedback(.impact(weight: .heavy), trigger: taps)
        .accessibilityLabel("Start welcome")
    }
}

/// Same family as the start screen's ENGINE START button: dark face, metal bezel, red LED ring.
private struct MicButtonFace: View {
    let diameter: CGFloat
    let active: Bool

    private static let red = Color(red: 1.0, green: 0.16, blue: 0.12)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let glow: Double = active ? 0.55 + 0.45 * sin(t * 2 * Double.pi / 1.1) : 0.7
            face(glow: glow)
        }
    }

    private func face(glow: Double) -> some View {
        let d = diameter
        let metal = [0.55, 0.18, 0.7, 0.22, 0.62, 0.16, 0.55].map { Color(white: $0) }
        return ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.21), Color(white: 0.05)],
                                     startPoint: .top, endPoint: .bottom))
            Circle()
                .strokeBorder(AngularGradient(colors: metal, center: .center,
                                              startAngle: .degrees(0), endAngle: .degrees(360)),
                              lineWidth: d * 0.045)
            Circle()
                .strokeBorder(Self.red, lineWidth: d * 0.018)
                .padding(d * 0.075)
                .shadow(color: Self.red.opacity(0.9 * glow), radius: 3 + 9 * glow)
                .opacity(0.3 + 0.7 * glow)
            Image(systemName: "mic.fill")
                .font(.system(size: d * 0.36, weight: .bold))
                .foregroundStyle(active ? Color.white : Self.red)
                .shadow(color: Self.red.opacity(glow), radius: 4 + 10 * glow)
        }
        .frame(width: d, height: d)
        .contentShape(Circle())
        .shadow(color: Color.black.opacity(0.3), radius: 12, y: 6)
    }
}

/// Presses in like the ENGINE START button.
private struct MicButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
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
        case .cyanBreathing, .cyanBurstFlash: return .cyan
        case .redBreathing, .redBurstFlash: return .red
        }
    }

    private func opacity(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        switch scene {
        case .purpleSteady: return 1
        case .redBreathing, .yellowBreathing, .cyanBreathing:
            return 0.25 + 0.75 * (0.5 + 0.5 * sin(t * 2 * .pi / 2.5))                   // ~2.5 s breath
        case .redBurstFlash, .blueBurstFlash, .purpleBurstFlash, .cyanBurstFlash:
            return Int(t * 8) % 2 == 0 ? 1 : 0.1                                          // fast flash
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

/// Under the microphone button: what the assistant is doing, what it heard and where to.
private struct AssistantStatusView: View {
    @ObservedObject var assistant: WelcomeAssistant

    var body: some View {
        VStack(spacing: 2) {
            Text(assistant.status).font(.subheadline.weight(.semibold))
            if let heard = assistant.lastHeard {
                Text("Heard: \"\(heard)\"").font(.caption).foregroundColor(.secondary)
            }
            if let destination = assistant.lastDestination {
                Text("Destination: \(destination)").font(.caption.bold())
            }
        }
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// Diagnostics of the last Welcome: the commute check, the music shortcut, the understanding engine.
private struct AssistantDiagnosticsView: View {
    @ObservedObject var assistant: WelcomeAssistant

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Assistant").font(.headline)
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
        case true?: return now + "  ·  from the car, \(frame): \(obd.lightsFrame.map { $0.hexString() } ?? "--")"
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
