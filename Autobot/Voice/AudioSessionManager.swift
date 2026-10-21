// AudioSessionManager.swift
// Owns this app's AVAudioSession. Each mode decides what happens to other apps' audio
// (e.g. QQ Music) while we speak or listen.

import AVFoundation

final class AudioSessionManager {

    nonisolated enum Mode {
        /// Short prompt, navigation style: other apps keep playing, just quieter.
        case duckOthers
        /// Pauses other apps and turns on the microphone (car mic under CarPlay).
        case conversation
        /// Playback only; other apps stay paused until `release()`.
        case holdOthersPaused
        /// Engine start-up sound on the start screen: plays alongside other apps' audio, out of
        /// the current output (phone speaker, or the car under CarPlay). Record-capable, so
        /// car-audio detection keeps working meanwhile.
        case engineSound
    }

    /// Activating/deactivating the session can block for a while, so it runs off the main thread
    /// (iOS warns that doing it on the main thread can make the UI unresponsive).
    private let queue = DispatchQueue(label: "Autobot.AudioSession")

    /// True when another app (e.g. a music app) is currently playing.
    var isOtherAudioPlaying: Bool { AVAudioSession.sharedInstance().isOtherAudioPlaying }

    func activate(_ mode: Mode) async {
        await perform("activate \(mode)") { session in
            try Self.setCategory(for: mode, on: session)
            try session.setActive(true)
        }
    }

    /// Deactivates our session and tells other apps they may resume / un-duck.
    func release() async {
        await perform("release") { session in
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Helpers

    private func perform(_ label: String, _ work: @escaping @Sendable (AVAudioSession) throws -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                do {
                    try work(AVAudioSession.sharedInstance())
                } catch {
                    print("Audio session \(label) error:", error)
                }
                done.resume()
            }
        }
    }

    private nonisolated static func setCategory(for mode: Mode, on session: AVAudioSession) throws {
        switch mode {
        case .duckOthers:
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        case .conversation:
            // Not mixable, so other apps are interrupted (paused)
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
        case .holdOthersPaused:
            try session.setCategory(.playback, mode: .voicePrompt, options: [])
        case .engineSound:
            // Same as CarPlayMonitor's detection category, so starting detection mid-sound
            // doesn't change the route. No Bluetooth HFP: an active HFP (phone-call) link to
            // headphones / the car takes Bluetooth radio time away from the lamp's BLE connection.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        }
    }
}
