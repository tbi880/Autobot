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
            LampStateView(lighting: app.lighting, lamp: app.lamp, powerMode: app.powerMode)
            DoorTestView(doors: app.doors)
            AssistantView(assistant: app.assistant, onTest: app.testWelcome,
                          onTestCommute: app.testCommute)
            PowerModeTestView(powerMode: app.powerMode, onTest: app.testPowerMode)
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
        guard let gear = manual.gear else { return "gear --" }
        return "gear \(gear)" + (manual.gearFromCar ? "" : " (est.)")
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
                    Text("Driving in D")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text("Top gear " + String(format: "%.1f", manual.topGearRatio)
                     + " r/min per km/h  ·  GPS \(gpsSpeedText) km/h")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
        scene == .purpleSteady ? Color(red: 0.5, green: 0, blue: 1) : Color.red
    }

    private func opacity(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        switch scene {
        case .purpleSteady: return 1
        case .redBreathing: return 0.25 + 0.75 * (0.5 + 0.5 * sin(t * 2 * .pi / 2.5))   // ~2.5 s breath
        case .redBurstFlash: return Int(t * 8) % 2 == 0 ? 1 : 0.1                       // fast flash
        }
    }
}

/// Test buttons until the OBD2 connection provides real door data.
private struct DoorTestView: View {
    @ObservedObject var doors: DoorMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Door test").font(.headline)
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
