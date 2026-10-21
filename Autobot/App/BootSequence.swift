// BootSequence.swift
// State behind the start screen (BootView): the ENGINE START button, then the progress ring.
//
//   press       haptics + engine start-up sound (EngineSoundPlayer); AppModel.ignite() starts the
//               lamp Bluetooth search and car-audio (CarPlay) detection at the same moment
//   0 → 50 %    always climbs slowly, even with nothing connected; holds at 50 % until the lamp connects
//   50 → 90 %   once the lamp is connected; holds at 90 % until car audio connects
//   90 → 100 %  once car audio is connected, then the dashboard takes over (onFinished)
//
// The engine sound keeps idling until car audio is connected (after playing the full start-up).
// This only drives the screen; lamp and CarPlay logic are unchanged.
// Speeds and timings: AppConfig.Boot.

import Combine
import CoreHaptics
import SwiftUI
import UIKit

final class BootSequence: ObservableObject {

    enum Phase { case ready, booting, finished }

    @Published private(set) var phase = Phase.ready
    @Published private(set) var progress = 0.0              // 0…100
    @Published private(set) var lampConnected = false       // stays true once seen during boot
    @Published private(set) var carAudioConnected = false   // stays true once seen during boot
    @Published private(set) var ignitedAt: Date?
    @Published private(set) var completedAt: Date?

    /// Called once the dashboard should take over.
    var onFinished: (() -> Void)?

    private let lamp: LampController
    private let carPlay: CarPlayMonitor
    private let engineSound: EngineSoundPlayer
    private let haptics = IgnitionHaptics()
    private var subscriptions = Set<AnyCancellable>()
    private var runTask: Task<Void, Never>?
    private var soundStop: Task<Void, Never>?

    init(lamp: LampController, carPlay: CarPlayMonitor, engineSound: EngineSoundPlayer) {
        self.lamp = lamp
        self.carPlay = carPlay
        self.engineSound = engineSound
    }

    /// Highest point the progress may reach right now.
    var cap: Double {
        guard lampConnected else { return 50 }
        return carAudioConnected ? 100 : 90
    }

    /// Waiting at 50 % or 90 % for a connection.
    var isHolding: Bool { phase == .booting && cap < 100 && progress >= cap - 0.01 }

    /// The lamp controller's own status ("Scanning for Pocket Link…", "Bluetooth is off…").
    var lampStatus: String {
        guard AppConfig.Testing.simulateBootConnections, lampConnected else { return lamp.status }
        return "Connected: Pocket Link (simulated)"
    }

    var statusText: String {
        if completedAt != nil { return "All systems go" }
        if !lampConnected { return "Searching for lamp" }
        if !carAudioConnected { return "Waiting for car audio" }
        return "Car audio connected"
    }

    // MARK: Button

    /// Finger down on the button: get audio and haptics ready so the start is instant.
    func pressBegan() {
        guard phase == .ready else { return }
        haptics.prepare()
        haptics.press()
        let sound = engineSound
        Task { await sound.prepare() }
    }

    /// The button was pressed: start-up effects, sound and the progress.
    func ignite() {
        guard phase == .ready else { return }
        phase = .booting
        ignitedAt = .now
        haptics.ignition()
        let sound = engineSound
        Task { await sound.play() }

        if AppConfig.Testing.simulateBootConnections {
            lampConnected = true
            carAudioConnected = true
        } else {
            lamp.$isReady.filter { $0 }.first()
                .sink { [weak self] _ in self?.lampConnected = true }
                .store(in: &subscriptions)
            carPlay.$isConnected.filter { $0 }.first()
                .sink { [weak self] _ in self?.carAudioConnected = true }
                .store(in: &subscriptions)
        }

        runTask = Task { [weak self] in await self?.run() }
    }

    // MARK: Progress

    private func run() async {
        let clock = ContinuousClock()
        let start = clock.now
        var last = start
        while progress < 100 {
            try? await Task.sleep(for: .milliseconds(16))
            if Task.isCancelled { return }
            let now = clock.now
            let dt = (now - last).inSeconds
            last = now
            let elapsed = (now - start).inSeconds
            stopEngineSoundIfCarAudio(elapsed: elapsed)
            if elapsed >= AppConfig.Boot.progressStart { advance(by: dt) }
        }

        completedAt = .now
        haptics.success()
        try? await Task.sleep(for: AppConfig.Boot.holdAtFull)
        stopEngineSoundIfCarAudio(elapsed: .infinity)
        await soundStop?.value                  // the Welcome starts only after the engine is quiet
        phase = .finished
        onFinished?()
    }

    private func advance(by dt: Double) {
        let cap = self.cap
        guard progress < cap else { return }
        let rate: Double
        if progress < 50 {
            rate = lampConnected ? AppConfig.Boot.rateToHalfLampReady : AppConfig.Boot.rateToHalf
        } else if progress < 90 {
            rate = AppConfig.Boot.rateToNinety
        } else {
            rate = AppConfig.Boot.rateToFull
        }
        // Ease into a waiting point instead of stopping dead
        let ease = cap < 100 ? min(1, max(0.15, (cap - progress) / AppConfig.Boot.easeZone)) : 1
        let old = progress
        progress = min(cap, progress + rate * ease * dt)
        if (old < 50 && progress >= 50) || (old < 90 && progress >= 90) {
            haptics.tick()
        }
    }

    /// Car audio is connected: the engine sound ends (but never before the start-up has played).
    private func stopEngineSoundIfCarAudio(elapsed: Double) {
        guard carAudioConnected, soundStop == nil, elapsed >= AppConfig.Boot.minEngineSound else { return }
        let sound = engineSound
        soundStop = Task { await sound.stop(fadeOut: AppConfig.Boot.engineFadeOut) }
    }
}

private extension Duration {
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

// MARK: - Haptics

/// The press "click", the starter cranking, the engine firing, and ticks at 50 / 90 / 100 %.
/// Follows the same timeline as the sound (AppConfig.Boot).
final class IgnitionHaptics {

    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?

    func prepare() {
        guard supported, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            try engine.start()
            self.engine = engine
        } catch {
            print("Haptics error:", error)
        }
    }

    func press() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7)
    }

    func ignition() {
        prepare()
        guard let engine else {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            return
        }
        do {
            let pattern = try CHHapticPattern(events: Self.ignitionEvents(),
                                              parameterCurves: [Self.fireDecay()])
            try engine.start()
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
        } catch {
            print("Haptics error:", error)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    func tick() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private static func ignitionEvents() -> [CHHapticEvent] {
        let crank = AppConfig.Boot.crankStart
        let fire = AppConfig.Boot.catchTime
        var events = [transient(at: 0, intensity: 1, sharpness: 0.9)]          // button click
        var t = crank
        while t < fire {                                                        // cranking pulses
            events.append(transient(at: t, intensity: 0.6, sharpness: 0.2))
            t += 1 / 7.3
        }
        events.append(continuous(at: crank, duration: fire - crank, intensity: 0.35, sharpness: 0.1))
        events.append(transient(at: fire, intensity: 1, sharpness: 0.7))         // engine fires
        events.append(continuous(at: fire, duration: 1.3, intensity: 1, sharpness: 0.35))
        return events
    }

    /// The rumble after the engine fires dies away.
    private static func fireDecay() -> CHHapticParameterCurve {
        CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 1),
                .init(relativeTime: 0.35, value: 0.7),
                .init(relativeTime: 1.3, value: 0),
            ],
            relativeTime: AppConfig.Boot.catchTime)
    }

    private static func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient,
                      parameters: [.init(parameterID: .hapticIntensity, value: intensity),
                                   .init(parameterID: .hapticSharpness, value: sharpness)],
                      relativeTime: time)
    }

    private static func continuous(at time: TimeInterval, duration: TimeInterval,
                                   intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous,
                      parameters: [.init(parameterID: .hapticIntensity, value: intensity),
                                   .init(parameterID: .hapticSharpness, value: sharpness)],
                      relativeTime: time,
                      duration: duration)
    }
}
