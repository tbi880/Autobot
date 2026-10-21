// AppConfig.swift
// Every user-facing phrase and tuning value lives here, so behaviour can be
// adjusted without digging through the rest of the code.

import AVFoundation   // AVSpeechSynthesisVoiceGender
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
        /// "Buffer zone" when Power Mode switches: red burst flash + announcement for this long,
        /// then the speed is checked again before the new lighting is applied.
        static let switchBufferDuration: Duration = .seconds(3)
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
        /// CarPlay counts as connected once car audio has been present this long, giving the
        /// head unit a moment before the greeting starts (and ignoring one-off blips).
        static let connectDelay: Duration = .milliseconds(500)
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
        /// Apple's voice processing on the microphone (as in FaceTime/phone calls): echo
        /// cancellation (removes sound coming from the car speakers), noise suppression
        /// (road/wind/fan noise) and automatic gain for speech.
        static let voiceProcessing = true
        /// In the final result, words recognised with less confidence than this (0…1) are dropped
        /// as background noise. 0 keeps everything.
        static let minWordConfidence: Float = 0.3
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
        /// Shortcut: 1. Open URLs (Shortcut Input = Google Maps link)  2. QQ音乐 - 继续播放.
        /// If it fails or is cancelled, the Google Maps link is opened again (x-error / x-cancel).
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

    /// "Power Mode Activated": sci-fi female AI voice - clear, slightly bright, with a
    /// shimmering digital/metallic sheen and some space. Raise combMix / ringModMix for more effect.
    enum SciFiVoice {
        /// .female or .male.
        static let gender: AVSpeechSynthesisVoiceGender = .female
        /// Preferred accent, tried first (falls back to any English voice of that gender).
        static let language = "en-US"
        /// Speech rate relative to the normal voice (1.0 = same). Slightly measured.
        static let rateFactor: Float = 0.95
        /// Voice pitch (0.5…2.0). A touch brighter than natural.
        static let pitchMultiplier: Float = 1.05
        /// Extra pitch shift in cents (−2400…2400).
        static let pitchCents: Float = 0
        /// Comb filter (metallic shimmer): delay in ms, feedback 0…0.9, mix 0…1.
        static let combDelayMs: Double = 1.5
        static let combFeedback: Float = 0.45
        static let combMix: Float = 0.3
        /// Ring modulator (digital texture): carrier frequency and mix 0…1.
        static let ringModHz: Double = 220
        static let ringModMix: Float = 0.06
        /// Plate reverb amount 0…100 (a spaceship-cabin sense of space).
        static let reverbMix: Float = 14
        /// Loudness: soft-limiter drive (1 = plain normalisation, higher = denser/louder).
        static let drive: Float = 1.4
        /// Player volume 0…1. The voice is already normalised to full scale.
        static let volume: Float = 1.0
    }
}
