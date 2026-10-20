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

    enum Lamp {
        /// How many times to resend a mode command if the lamp reports a different mode afterwards.
        static let modeRetries = 2
        /// How many times to resend a packet the lamp answered with "busy" or "checksum error".
        static let nackRetries = 2
        /// Set the lamp's custom colour to red before red gradient breathing. Some firmware breathes
        /// the custom colour instead of the gradient parameter (seen as purple breathing after the
        /// purple steady state). Set to false if this ever makes the breathing colourful instead.
        static let setRedBeforeBreathing = true
    }

    enum CarPlay {
        /// CarPlay counts as connected the moment car audio appears (no delay).
        /// It only counts as disconnected after car audio has been gone this long, so short
        /// route blips (e.g. while this app switches audio modes) don't start a new "drive".
        static let disconnectGrace: Duration = .seconds(3)
        /// Re-check the audio route this often, in case no route-change notification arrives
        /// (e.g. CarPlay connects while nothing is playing).
        static let pollInterval: Duration = .seconds(1)
    }

    enum Listening {
        /// Languages recognised at the same time. Each inner list is one language,
        /// its locales tried in order until one is available on this iPhone.
        static let languages: [[String]] = [
            ["en-NZ", "en-US"],     // English
            ["zh-CN"],              // Mandarin
        ]
        /// After you stop talking, wait at most this long for the final (most accurate) results.
        static let finalResultTimeout: TimeInterval = 1.5
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
        /// Shortcut with a single step: QQ Music "继续播放" (resume the last song).
        /// Google Maps is opened afterwards by the Shortcuts app's callback, even if that step fails.
        /// Used only when no music was playing when the car connected.
        static let shortcutName = "Lamp Drive"
        /// How long to wait for the music to start before giving up on "The music is now continued".
        static let startTimeout: TimeInterval = 10
    }

    enum Phrases {
        static var welcome: String { "Welcome back, \(Driver.name)." }
        static let askDestination = "Where is our destination today?"
        static let foundPlaces = "Find these places, you can finalize the destination manually."
        static func navigating(to name: String) -> String { "Navigating to \(name)." }
        static let musicContinued = "The music is now continued."
        static let powerOn = "Power Mode Activated"
        static let powerOff = "Power Mode Deactivated"
        static let doorOpen = "Door open detected"
    }

    /// "Power Mode Activated": calm, refined British male voice with a light digital
    /// "AI assistant" sheen (not a heavy robot). Raise combMix / ringModMix for more metal.
    enum RobotVoice {
        /// Preferred accent, tried first (falls back to any English male voice).
        static let language = "en-GB"
        /// Speech rate relative to the normal voice (1.0 = same). Unhurried.
        static let rateFactor: Float = 0.92
        /// Voice pitch (0.5…2.0). Close to natural.
        static let pitchMultiplier: Float = 0.95
        /// Extra pitch shift in cents (−2400…2400). Lower = deeper.
        static let pitchCents: Float = -50
        /// Comb filter (digital sheen): delay in ms, feedback 0…0.9, mix 0…1.
        static let combDelayMs: Double = 2
        static let combFeedback: Float = 0.35
        static let combMix: Float = 0.2
        /// Ring modulator (robotic buzz): carrier frequency and mix 0…1. Almost off.
        static let ringModHz: Double = 90
        static let ringModMix: Float = 0.04
        /// Plate reverb amount 0…100 (a bit of space, like a speaker in a room).
        static let reverbMix: Float = 8
        /// Loudness: soft-limiter drive (1 = plain normalisation, higher = denser/louder).
        static let drive: Float = 1.4
        /// Player volume 0…1. The voice is already normalised to full scale.
        static let volume: Float = 1.0
    }
}
