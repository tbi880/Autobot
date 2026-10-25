// AppConfig.swift
// Every user-facing phrase and tuning value lives here, so behaviour can be
// adjusted without digging through the rest of the code.

import AVFoundation   // AVSpeechSynthesisVoiceGender
import Foundation

nonisolated enum AppConfig {
    
    enum TestMode {
        /// Simulates successful lamp Bluetooth and CarPlay connections at start-up.
        static let enabled = false
    }

    enum Driver {
        static let name = "Tim"
    }

    /// Power Mode: red gradient breathing when driving hard, purple steady otherwise.
    enum PowerMode {
        enum Trigger {
            /// Manual shifting (M) worked out from RPM, speed and pedal (AppConfig.Manual).
            /// Standard OBD2 doesn't report the gear selector position itself (see README).
            case manualShift
            /// Engine RPM at or above a threshold (AppConfig.Engine).
            case engineRPM
            /// GPS speed (AppConfig.Speed), the original trigger.
            case speed
        }
        static let trigger: Trigger = .manualShift
        /// "Buffer zone" when Power Mode switches: red burst flash + announcement for this long,
        /// then the trigger is checked again before the new lighting is applied.
        static let switchBufferDuration: Duration = .seconds(3)
    }

    /// Engine RPM trigger (EngineMonitor), used when PowerMode.trigger is .engineRPM.
    enum Engine {
        /// At or above this engine speed (r/min) the lamp switches to red gradient breathing.
        static let powerModeThresholdRpm: Double = 2500
        /// The RPM must stay at or above the threshold this long (seconds) before Power Mode
        /// switches on, so a momentary blip doesn't count.
        static let confirmOn: TimeInterval = 0.5
        /// …and below it this long before Power Mode switches off. Longer, so the dip below the
        /// threshold after each upshift doesn't end Power Mode in the middle of an acceleration.
        /// Set it to about 1 to make it switch back as quickly as the old speed trigger did.
        static let confirmOff: TimeInterval = 5
    }

    /// Manual-shifting detection (ManualShiftDetector), used when PowerMode.trigger is .manualShift.
    /// Set up for a Mazda CX-5 2.2 diesel (2015) with the 6-speed automatic (SKYACTIV-Drive).
    enum Manual {
        /// Gearbox ratios, 1st to 6th. Only their proportions matter.
        static let gearRatios: [Double] = [3.552, 2.022, 1.452, 1.000, 0.708, 0.599]
        /// Top gear in engine r/min per km/h: 2000 r/min at 110 km/h on the speedometer, which reads
        /// a few % high, so about 105 km/h as OBD2 reports it. Fine-tuned while cruising.
        static let topGearRpmPerKmh: Double = 2000.0 / 105.0
        /// RPM ÷ speed may be this far (fraction) from a gear's value and still count as that gear.
        static let gearTolerance = 0.07
        /// Below this speed (km/h) the gear isn't worked out (torque converter slip, coarse speed).
        static let minSpeedForGear: Double = 12
        /// A gear counts once it has been seen in this many readings in a row.
        static let gearConfirmReadings = 2
        /// A new gear seen within this many seconds of the old one is a shift.
        static let shiftWindow: TimeInterval = 3
        /// Fine-tune the top-gear value while cruising in top gear at this speed (km/h) or more.
        static let learnTopGear = true
        static let learnMinSpeed: Double = 70
        static let learnRate = 0.02

        /// Rule 1: the highest RPM D settles at for a pedal position (0–100 %); D shifts up before.
        /// Straight lines in between. More revs than this for `revHoldTime` = the gear is held.
        static let dModeCeiling: [(demand: Double, rpm: Double)] = [
            (0, 2600), (40, 3000), (70, 3800), (90, 4600), (100, 4800),
        ]
        static let revHoldTime: TimeInterval = 1
        /// D shifts up before this even with the pedal floored, so above it a moment is enough.
        static let overRevRPM: Double = 4800
        static let overRevHoldTime: TimeInterval = 0.3
        /// No detection below this speed (km/h), e.g. revving in P or N.
        static let minSpeed: Double = 10

        /// Rule 2: a downshift with the foot off (pedal at or below this %), at this speed (km/h) or
        /// more, landing at this RPM or more, is engine braking by hand.
        static let footOffDemand: Double = 5
        static let engineBrakeMinSpeed: Double = 25
        static let engineBrakeRPM: Double = 1800
        /// Without pedal data: losing this many km/h within `trendWindow` seconds counts as foot off.
        static let slowingDown: Double = 1
        static let trendWindow: TimeInterval = 2

        /// Manual ends once the RPM has stayed at or below this for `calmTime` seconds.
        static let calmRPM: Double = 2500
        static let calmTime: TimeInterval = 10
    }

    /// GPS speed trigger (SpeedMonitor), used when PowerMode.trigger is .speed.
    enum Speed {
        /// At or above this speed the lamp switches to red gradient breathing.
        static let powerModeThresholdKmh: Double = 90
        /// Consecutive GPS readings (about 1 per second) needed before switching state,
        /// so the lamp doesn't flicker while hovering around the threshold.
        static let confirmReadings = 2
        /// Ignore GPS speed readings less accurate than this (m/s).
        static let maxSpeedAccuracy: Double = 5
    }

    /// OBD2 Bluetooth adapter (OBDAdapter, ELM327 protocol).
    enum OBD {
        /// Connects to the first adapter advertising service FFF0 whose name starts with this.
        static let deviceName = "KONNWEI"
        /// ELM327 protocol ("ATSP…"): 6 = ISO 15765-4 CAN, 11-bit IDs, 500 kbit/s, as MAXOBD
        /// detected on this car. "0" lets the adapter search (slower first connection).
        static let protocolNumber = "6"
        /// Requests go straight to the engine ECU (7E0, it answers from 7E8) instead of to every
        /// ECU. nil = the standard broadcast address (7DF).
        static let requestHeader: String? = "7E0"
        /// Pause between two rounds of live data. A round is 2–3 requests of roughly 50–150 ms
        /// each, so this gives about 3 rounds a second.
        static let pollInterval: Duration = .milliseconds(100)
        /// How long to wait for the ">" prompt after a command (seconds)…
        static let replyTimeout: TimeInterval = 1.5
        /// …after ATZ (the adapter restarts)…
        static let resetTimeout: TimeInterval = 3
        /// …and for "0100", "0120"… and "01A0" (the ECU may take a moment to wake up).
        static let probeTimeout: TimeInterval = 5
        /// Wait between attempts while the engine ECU doesn't answer (ignition off) or the set-up failed.
        static let retryDelay: Duration = .seconds(3)
        /// Rounds in a row without an RPM answer before the set-up starts again.
        static let maxMissedReadings = 5
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

    /// Start screen: ENGINE START button, then the boot progress ring (BootSequence, BootView,
    /// EngineSoundPlayer).
    enum Boot {
        /// Start-up timeline in seconds after the button is pressed. Sound, haptics and animation
        /// all follow it: the starter cranks from `crankStart`, the engine fires at `catchTime`.
        static let crankStart = 0.12
        static let catchTime = 0.95
        /// The button turns into the progress ring over this long, starting when the engine fires.
        static let morphDuration = 0.8
        /// The percentage starts counting this long after the press.
        static let progressStart = 1.5
        /// Progress speed in % per second.
        /// 0 → 50 % always runs, even with nothing connected (faster if the lamp is already there);
        /// 50 → 90 % needs the lamp; 90 → 100 % needs car audio (CarPlay).
        static let rateToHalf = 9.0
        static let rateToHalfLampReady = 16.0
        static let rateToNinety = 14.0
        static let rateToFull = 20.0
        /// Within this many % of a point where it has to wait (50 or 90) the progress slows down,
        /// so it eases in instead of stopping dead.
        static let easeZone = 8.0
        /// Pause at 100 % before the dashboard appears.
        static let holdAtFull: Duration = .milliseconds(450)
        /// Length of the fly-through-the-ring transition into the dashboard (seconds).
        static let dashboardTransition = 1.1
        /// The Welcome starts only after the transition (plus this margin), so starting the
        /// voice, microphone and audio session doesn't make the animation stutter.
        static let welcomeDelayAfterTransition = 0.25
        /// The engine sound always plays at least this long (the whole start-up), even if car audio
        /// is already connected; after that it stops as soon as car audio is connected.
        static let minEngineSound = 3.6
        /// Fade-out when the engine sound stops (seconds).
        static let engineFadeOut = 0.8
        /// Engine sound volume 0…1.
        static let engineVolume: Float = 1.0
    }

    enum Listening {
        /// Languages recognised at the same time. Each inner list is one language,
        /// its locales tried in order until one is available on this iPhone.
        static let languages: [[String]] = [
            ["en-NZ", "en-US"],     // English
            ["zh-CN"],              // Mandarin
        ]
        /// Apple's voice processing on the microphone (as in FaceTime/phone calls): echo
        /// cancellation, noise suppression and automatic gain.
        /// OFF: on this setup the voice-processing unit failed to render ("vpio render err -1")
        /// and no audio reached the recogniser, so nothing was recognised.
        static let voiceProcessing = false
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

    /// Weekday-morning commute (CommuteCheck): when the Welcome starts near the saved place marked
    /// Home, on a weekday in these hours, the destination question is skipped and navigation to the
    /// place marked Work starts through the Directions shortcut below.
    enum Commute {
        /// Local hours when it applies: 7:00 to 9:59.
        static let hours = 7..<10
        /// Days it applies (Calendar weekday: 1 = Sunday, 2 = Monday … 7 = Saturday): Monday to Friday.
        static let weekdays: Set<Int> = [2, 3, 4, 5, 6]
        /// Counts as "at Home" within this many metres of Home's address.
        static let homeRadius: Double = 300
        /// GPS fixes older than this (seconds) or less accurate than this (metres) are not trusted.
        static let maxLocationAge: TimeInterval = 120
        static let maxLocationAccuracy: Double = 200
        /// Waits at most this long for a usable GPS fix (the check runs during the greeting).
        static let locationTimeout: TimeInterval = 6
        /// Looking up Home's coordinates from its address (only needed once per address; cached).
        static let geocodeTimeout: TimeInterval = 5
    }

    enum Music {
        /// The shortcuts below start QQ Music and open Google Maps. They run only when no music was
        /// playing when the car connected; if iOS refuses to open Shortcuts, the app opens
        /// Google Maps directly (then without music).
        ///
        /// Navigation (weekday commute, saved place with an exact address): the route starts by
        /// itself, so it doesn't matter that QQ Music comes to the front afterwards.
        /// Shortcut Input = Google Maps navigation link.
        ///   1. Open (Shortcut Input)  -> Google Maps, starts the route
        ///   2. QQ音乐 - 最近播放
        static let navigateShortcutName = "最近播放的歌"
        /// Everything else (a place to search, or no destination): you pick the result in
        /// Google Maps, so Google Maps must end up in front. Shortcut Input = the search text
        /// (no input when there's no destination).
        ///   1. QQ音乐 - 继续播放
        ///   2. If Shortcut Input has any value: Google Maps - Search (query = Shortcut Input)
        ///      Otherwise: Open App - Google Maps
        static let searchShortcutName = "Lamp Drive"
        /// How long to wait for the music to start before giving up on "The music is now continued".
        static let startTimeout: TimeInterval = 10
    }

    enum Phrases {
        static var welcome: String { "Welcome back, \(Driver.name)." }
        static let askDestination = "Where is our destination today?"
        static let foundPlaces = "Find these places, you can finalize the destination manually."
        static func navigating(to name: String) -> String { "Navigating to \(name)." }
        static let navigatingToWork = "Navigating to work."
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
