// AudioSessionManager.swift
// Owns this app's AVAudioSession. Each mode decides what happens to other apps' audio
// (e.g. QQ Music) while we speak or listen.

import AVFoundation

final class AudioSessionManager {

    enum Mode {
        /// Short prompt, navigation style: other apps keep playing, just quieter.
        case duckOthers
        /// Pauses other apps and turns on the microphone (car mic under CarPlay).
        case conversation
        /// Playback only; other apps stay paused until `release()`.
        case holdOthersPaused
    }

    private let session = AVAudioSession.sharedInstance()

    /// True when another app (e.g. a music app) is currently playing.
    var isOtherAudioPlaying: Bool { session.isOtherAudioPlaying }

    func activate(_ mode: Mode) {
        do {
            switch mode {
            case .duckOthers:
                try session.setCategory(.playback, mode: .voicePrompt,
                                        options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            case .conversation:
                // Not mixable, so other apps are interrupted (paused)
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetooth])
            case .holdOthersPaused:
                try session.setCategory(.playback, mode: .voicePrompt, options: [])
            }
            try session.setActive(true)
        } catch {
            print("Audio session (\(mode)) error:", error)
        }
    }

    /// Deactivates our session and tells other apps they may resume / un-duck.
    func release() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Audio session release error:", error)
        }
    }
}
