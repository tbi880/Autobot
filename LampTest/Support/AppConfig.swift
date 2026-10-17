// AppConfig.swift
// Every user-facing phrase and tuning value lives here, so behaviour can be
// adjusted without digging through the rest of the code.

import Foundation

nonisolated enum AppConfig {

    enum Driver {
        static let name = "Tim"
    }

    enum Speed {
        /// At or above this speed the lamp switches to red gradient breathing.
        static let powerModeThresholdKmh: Double = 90
        /// Consecutive GPS readings (about 1 per second) needed before switching state,
        /// so the lamp doesn't flicker while hovering around the threshold.
        static let confirmReadings = 2
        /// Ignore GPS speed readings less accurate than this (m/s).
        static let maxSpeedAccuracy: Double = 5
    }

    enum CarPlay {
        /// Wait this long after the car audio route appears before treating CarPlay as connected.
        static let settleDelay: Duration = .seconds(3)
    }

    enum Listening {
        /// Speech recognition languages, tried in order.
        static let localeIdentifiers = ["en-NZ", "en-US"]
        /// Give up if nothing has been said within this time.
        static let noSpeechTimeout: TimeInterval = 10
        /// Stop listening after this much silence following the last word.
        static let endOfSpeechSilence: TimeInterval = 1.5
        /// Hard limit for one reply.
        static let maxListeningTime: TimeInterval = 20
        /// Max time to wait for Apple Intelligence before falling back to keywords.
        static let aiTimeout: Double = 6
    }

    enum Weather {
        /// The weather briefing is spoken between 6:00 and 11:59.
        static let morningHours = 6..<12
        static let requestTimeout: TimeInterval = 4
    }

    enum Music {
        /// Shortcut that starts QQ Music "我喜欢的歌" and then opens the Google Maps link it receives.
        /// Used only when no music was playing when the car connected.
        static let shortcutName = "Lamp Drive"
        /// How long to wait for the music to start before giving up on "The music is now continued".
        static let startTimeout: TimeInterval = 10
    }

    enum Phrases {
        static var welcome: String { "Welcome back, \(Driver.name)." }
        static let askDestination = "Where is our destination today?"
        static let foundPlaces = "Find these places, you can finalize the destination manually."
        static let musicContinued = "The music is now continued."
        static let powerOn = "Power Mode Activated"
        static let powerOff = "Power Mode Deactivated"
    }

    enum RobotVoice {
        /// Pitch shift in cents (−2400…2400). Lower = deeper.
        static let pitchCents: Float = -400
        /// 0…100. Strength of the robotic "radio" distortion.
        static let distortionMix: Float = 30
        /// 0…100. Amount of reverb.
        static let reverbMix: Float = 12
        static let speechRate: Float = 0.42
        static let pitchMultiplier: Float = 0.75
    }
}
