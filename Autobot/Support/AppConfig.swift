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

    /// This car's odometer, as the engine ECU reports it (22DD01: the DPF screen, the regeneration log
    /// and the DPF recorder).
    nonisolated enum Odometer {
        /// Added to the odometer reading, km. This car's odometer was adjusted: the distance it has really
        /// covered is this much more than the cluster shows. Everything Autobot shows, logs and exports
        /// uses the corrected figure; the cluster's own reading stays on the DPF screen and in the
        /// recording (odometer_shown_km). 0 = no correction. A change converts the odometer readings the
        /// regeneration log has saved, once.
        static let offsetKm: Double = 27_668
    }

    /// Power Mode: red gradient breathing in M, purple steady otherwise.
    enum PowerMode {
        enum Trigger {
            /// Manual shifting (M), from the car's real selector or learned M flag.
            case manualShift
            /// GPS speed (AppConfig.Speed), the original trigger.
            case speed
        }
        static let trigger: Trigger = .manualShift
        /// Show the red burst flash and announcement for this long before applying the current
        /// selector state. The M decision itself is made immediately from the car's selector.
        static let switchBufferDuration: Duration = .seconds(3)
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

    /// Both Bluetooth devices: the lamp (LampController) and the OBD2 adapter (OBDAdapter).
    enum Bluetooth {
        /// While a device isn't connected, the connection attempt is dropped and started again
        /// this often (ReconnectTimer), until the device is back.
        static let reconnectInterval: Duration = .seconds(60)
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
        /// Pause between live data rounds, after the speed and selector requests complete.
        static let pollInterval: Duration = .milliseconds(100)
        /// How long to wait for the ">" prompt after a command (seconds)…
        static let replyTimeout: TimeInterval = 1.5
        /// …after ATZ (the adapter restarts)…
        static let resetTimeout: TimeInterval = 3
        /// …and for the ECU wake / selector probes (the ECU may take a moment to wake up).
        static let probeTimeout: TimeInterval = 5
        /// Wait between attempts while the engine ECU doesn't answer (ignition off) or the set-up failed.
        static let retryDelay: Duration = .seconds(3)
        /// Rounds in a row without live data before the set-up starts again.
        static let maxMissedReadings = 5
        /// Read the transmission over UDS service 22 and drive Power Mode from the real lever:
        /// M = Power Mode, D/N/R/P = off. On this car (2015 CX-5 2.2D) the TCM's gear value
        /// (7E1 221E12) gives P/R/N and the gear, and D vs M comes from the M flag the M finder learns
        /// (MFinder, AppConfig.MFinder). Cars with the Ford-style selector DID (221E23) use that
        /// instead. If neither selector is available, Power Mode stays off until MFinder learns the
        /// M flag.
        static let readSelector = true
        /// The TCM/PCM replies are checked against known selector codes, so one reading is enough.
        static let selectorConfirmReadings = 1
        /// ECUs to try for the selector DID, in order: the engine/PCM (7E0, which answers 221E23 on
        /// most SkyActiv cars) first, then the transmission module (7E1, in case this car only
        /// exposes the selector there). The first that answers is used for the live reads.
        static let selectorHeaders: [String] = ["7E0", "7E1"]
        /// Diagnostics: show the raw bytes of every candidate transmission value on both ECUs on the
        /// dashboard, live, so the real M/D signal can be found by watching which one changes when the
        /// lever moves between M and D. While on, Power Mode stays off until a selector is found.
        /// Turn OFF once the right (header, DID, byte) is known.
        static let selectorDiagnostics = false
        /// The candidate transmission DIDs probed in diagnostics, grouped by ECU (PCM 7E0, TCM 7E1):
        /// selector lever (1E23), engaged gear (1E1F), gear (1E12), transmission gear (11B3).
        static let diagnosticDIDs: [(header: String, did: String)] = [
            ("7E0", "1E23"), ("7E0", "1E1F"), ("7E0", "1E12"), ("7E0", "11B3"),
            ("7E1", "1E23"), ("7E1", "1E1F"), ("7E1", "1E12"), ("7E1", "11B3"),
        ]
        /// Short timeout per diagnostic read, so a DID the ECU ignores doesn't stall the sweep.
        static let diagnosticTimeout: TimeInterval = 0.7
    }

    /// The gearbox (MazdaTCM): what tells M from D on this car.
    enum Transmission {
        /// The M flag of this car (2015 CX-5 2.2D), found with the M finder: TCM 7E1, DID 1E03,
        /// byte 0, bit 0x10 — 00 with the lever in D, 10 in M. Used for Power Mode (M = on) unless
        /// the M finder learns a different one (then that is used until "Forget").
        static let mFlag = BitSignal(header: "7E1", did: "1E03", byteIndex: 0, mask: 0x10,
                                     valueOff: 0x00, valueOn: 0x10, length: 1)
    }

    /// Real door state (DoorMonitor): which door is open, read from the car.
    enum Doors {
        /// Door detection on or off. Off for now: this car's body control module doesn't serve the
        /// door switches on HS-CAN (726 22C150 answers 7F2231, C100–C1FF and DA00–DAFF hold no door);
        /// they're on the MS-CAN body bus (OBD pins 3/11), which the KW905 doesn't connect to. While
        /// off, nothing door-related is read from the car and the dashboard hides the door rows; the
        /// code stays for an MS-CAN capable adapter later.
        static let enabled = false

        /// The body control module's door-ajar status: 726 DID C150 (replies from 72E), bit set =
        /// open. It's the Ford/Mazda BCM layout in the OBDb community database (listed for the CX-5,
        /// Mazda6, Mazda2, Focus, Explorer…; confirmed there on the 2007 Mazda6, 2009/2012 Mazda2 and
        /// 2012–18 Focus, not yet on a CX-5). This car's BCM answers the Ford battery DIDs of the same
        /// family (4027–402B), so there's a good chance it has this one too. OBDAdapter checks it
        /// once per session (see the log) and uses it for every door DoorFinder hasn't learned
        /// differently.
        ///   byte 1: 0x10 boot (liftgate), 0x08 rear right, 0x04 rear left
        ///   byte 2: 0x80 driver's door, 0x40 front passenger's door
        /// The BCM reports the driver's door as such, so it goes to the opening labelled "Driver"
        /// (the front right one on this right-hand-drive car, whatever the case is called).
        static let builtIn: [DoorMonitor.Opening: BitSignal] = [
            .frontLeft: bcmDoorBit(byte: 2, mask: 0x80),      // "Driver"
            .frontRight: bcmDoorBit(byte: 2, mask: 0x40),     // "Passenger"
            .rearLeft: bcmDoorBit(byte: 1, mask: 0x04),
            .rearRight: bcmDoorBit(byte: 1, mask: 0x08),
            .boot: bcmDoorBit(byte: 1, mask: 0x10),
        ]
        /// Read the built-in door status at all (off: only the doors DoorFinder learned).
        static let readBuiltIn = true      // only while `enabled`

        /// DIDs DoorFinder scans when a door has to be learned (the car doesn't answer the built-in
        /// status, or a door shows wrong): the BCM's body-status block around C150. DA00–DAFF was
        /// tried first and holds no door at all: of its 58 DIDs only DA13 (counts down by itself) and
        /// DA1E (battery voltage, sags when the courtesy lamps come on) ever change. The scan result
        /// is kept until this changes.
        static let scanPlan: [(header: String, ranges: [ClosedRange<Int>])] = [
            ("726", [0xC100...0xC1FF]),
        ]
        /// The ECU that owns the door switches; its candidates are preferred.
        static let preferredHeader = "726"
        /// Never a door switch, even if it slips into the scan: the 12V-battery values (4027–402B,
        /// drift and drowned the door bits on the first tries), the brake switch (DA05), the counter
        /// DA13 and the battery voltage DA1E.
        static let ignoredDIDs: Set<String> = [
            "726 4027", "726 4028", "726 4029", "726 402A", "726 402B", "726 DA05", "726 DA13", "726 DA1E",
        ]
        /// Wait per DID while scanning (seconds).
        static let scanTimeout: TimeInterval = 0.6
        /// Every supported DID is read this many times per snapshot (in separate passes), so a value
        /// that drifts within a position shows up as unsteady and drops out.
        static let readsPerSnapshot = 3
        /// Read the doors every this many rounds of live data (about 2 rounds a second).
        static let pollEveryRounds = 2

        private static func bcmDoorBit(byte: Int, mask: UInt8) -> BitSignal {
            BitSignal(header: "726", did: "C150", byteIndex: byte, mask: mask,
                      valueOff: 0x00, valueOn: mask, length: 3)
        }
    }

    /// The M finder (MFinder): finds the value that says "lever in M" on this car, once, by comparing
    /// snapshots taken with the lever in D and in M1. Only matters for that one-off search.
    enum MFinder {
        /// DIDs scanned, per ECU: the TCM (7E1) first, then the PCM (7E0). Ford/Mazda transmission
        /// values live in these blocks (1E12 gear, 1E1C oil temperature, 11B3, 163A, 17B3, DD01…).
        /// Widen it if a scan finds no difference; the scan result is kept until this changes.
        static let scanPlan: [(header: String, ranges: [ClosedRange<Int>])] = [
            ("7E1", [0x1100...0x11FF, 0x1600...0x17FF, 0x1E00...0x1EFF, 0xDD00...0xDD0F]),
            ("7E0", [0x1E00...0x1EFF]),
        ]
        /// Wait per DID while scanning (seconds). Unsupported DIDs are refused at once.
        static let scanTimeout: TimeInterval = 0.6
        /// Every supported DID is read this many times per snapshot (in separate passes), so values
        /// that change by themselves can be spotted and left out.
        static let readsPerSnapshot = 2
        /// Snapshots of each lever position before the best candidate is saved and used.
        static let snapshotsToConfirm = 2
        /// Values that only carry the gear or P/R/N (D1 and M1 read the same): never the M flag.
        static let ignoredDIDs: Set<String> = [
            "7E1 1E12", "7E0 1E12", "7E0 1E1F", "7E1 1E1F", "7E0 11B3", "7E1 11B3",
        ]
    }

    /// A/C temperature flash (ClimateTempFlash): blue burst flash when the A/C is set colder, red
    /// burst flash when it's set warmer.
    enum Climate {
        /// The A/C feature on or off. Off for now: the set temperature is on MS-CAN, which the KW905
        /// can't reach. While off, the dashboard hides the A/C row and the climate control unit isn't
        /// checked; the code stays for an MS-CAN capable adapter later.
        static let enabled = false
        /// How long a flash lasts after the last click of the temperature dial. Another click the
        /// same way starts the time again; a click the other way switches the colour at once.
        static let flashDuration: Duration = .seconds(3)
        /// The climate control unit, which holds the set temperature: request header in the Ford/Mazda
        /// layout (HVAC 733, replies from 73B). OBDAdapter checks once per connection whether it
        /// answers. On the 2015 CX-5 it's on the MS-CAN bus (OBD pins 3/11) and the KW905 only reaches
        /// HS-CAN (pins 6/14), so "not answering" is expected with that adapter — see README.
        static let unitHeader = "733"
        /// Do that check at all (one harmless "tester present", 3E00, per connection).
        static let checkUnit = true
        /// Dashboard test buttons: one click of the dial (the CX-5's dials move 0.5 °C a click)…
        static let testStep = 0.5
        /// …starting from this set temperature (°C).
        static let testStartTemperature = 22.0
    }

    /// DPF monitor (DPFMonitor, MazdaDPF): live DPF back pressure and RPM with charts, plus soot,
    /// regeneration and exhaust temperatures, read from the PCM only while its screen is open. Each
    /// read runs between two rounds of live data, so Power Mode, reverse and the turn signals keep
    /// working meanwhile. See README, "DPF monitor".
    enum DPF {
        /// The feature on or off. Off: the dashboard row is hidden.
        static let enabled = true
        /// Every read: RPM + DPF pressure, plus the next of these in turn. PM_GEN (the soot model a
        /// regeneration starts on) and the regeneration requests come round three times per cycle, the
        /// rest (PM_ACC_DSD, 044B, among them) once; a value the PCM doesn't answer drops out until the
        /// screen is opened again (not while the PCM answers nothing at all, and never one it has answered).
        static let rotation: [MazdaDPF.Value] = [
            .sootGenerated, .regenStatus, .soot, .exhaustTemps, .egr,
            .sootGenerated, .regenStatus, .dpfTemps, .sootDesired, .boost, .exhaustPressure,
            .sootGenerated, .regenStatus, .airFlow, .intakeShutter, .chargeAir, .oilTemp, .coolant,
            .regenCount, .regenDistance, .aftertreatment, .oilDilution, .oilDilutionEvents, .odometer,
        ]
        /// At least this long from the start of one read to the next, so live data keeps its pace.
        static let minInterval: Duration = .milliseconds(150)
        /// Chart history kept while the screen is open (seconds).
        static let historySeconds: TimeInterval = 600
        /// Chart windows to choose from (seconds).
        static let chartWindows: [TimeInterval] = [60, 180, 600]
        /// A value the PCM doesn't answer this many times in a row isn't asked again while the screen
        /// is open (reopen to try again), or for the rest of the drive by the regeneration log.
        static let missesBeforeSkipping = 3

        /// Soot gauge (PM_GEN, else PM_ACC, g/L; not 042B, which follows engine load), from Mazda's
        /// SKYACTIV-D 2.2 workshop manual and owner logs: a regeneration starts at about `pmGenTrigger`;
        /// from `sootHigh` it's close; the DPF light comes on at 8; at 10 it flashes and the PCM stops
        /// regenerating by itself (dealer); 13 sets the check-engine light (P2463); 17 means a new DPF (P242F).
        static let sootFullScale = 10.0
        static let sootHigh = 4.5
        static let sootWarning = 8.0
        static let sootCritical = 10.0
        /// Test mode (AppConfig.TestMode): simulated readings this often.
        static let simulationInterval: Duration = .milliseconds(400)

        /// Regeneration log (DPFRegenLog). While live data runs (screen closed): the flag (220380)
        /// every `regenCheckInterval`, plus the count, distance and soot every `logInterval`. Once a
        /// regeneration is running, every check also reads the soot, the exhaust / DPF temperatures and
        /// the count, so the start, peaks and end are recorded. While the DPF screen is open its own
        /// reads feed the log instead.
        static let logInterval: Duration = .seconds(60)
        /// The first log read after the engine ECU starts answering.
        static let logFirstDelay: Duration = .seconds(20)
        /// Entries kept, newest first.
        static let logMaxEntries = 100
        /// An entry counts as approximate when the last reading before the regeneration was longer ago
        /// than this (seconds): the distance driven in between is missing from it.
        static let logApproximateAfter: TimeInterval = 600
        /// Say "DPF regeneration started" (AppConfig.Phrases.dpfRegenStarted, the normal assistant
        /// voice) when the regeneration flag (220380) comes on.
        static let announceRegeneration = true
        static let regenCheckInterval: Duration = .seconds(15)
        /// Not said again within this long (a status that flickers, live data dropping and coming back).
        static let regenAnnounceCooldown: TimeInterval = 600
        /// The flag drops while the car is stopped although the regeneration carries on, so it only
        /// counts as ended without the count going up (interrupted) once it has been off this long while
        /// moving (above `movingSpeed` km/h) — or when the engine was switched off.
        static let regenOffConfirm: TimeInterval = 120
        static let movingSpeed = 5.0
        /// Health notes on the DPF screen: soot still at or above this after a completed regeneration
        /// (ash / clogging?), regenerations closer together than `shortIntervalKm` this many times in a
        /// row, and this many interrupted regenerations in a row (fuel in the oil). Soot after: Mazda expects
        /// about 0 after a complete regeneration (P243C), 0.5 g/L is too high (FORScan forum).
        static let postRegenSootHigh = 0.5
        static let shortIntervalKm = 150.0
        static let shortIntervalsInARow = 3
        static let interruptedInARow = 2

        /// Regeneration history finder (DPFHistoryFinder): the PCM keeps the distances of the last 10
        /// regenerations (what Mazda's dealer tool shows as "DPF regeneration distance 01–10"), but
        /// its DID isn't published. The finder scans these PCM DID blocks, in this order, for one DID
        /// holding 10 distances or a row of 10 consecutive DIDs holding one each, and confirms the one
        /// that shifts by one entry after a regeneration. 7E0 0300–04FF alone (the first scan, which
        /// only looked for single 10-byte DIDs) found nothing, so: the DPF block again (0380, 042C–0434
        /// live there; now rows of DIDs count too), the rest of Mazda's own 0000–0FFF block, then the
        /// Ford-style PCM blocks 1000–1FFF (11xx, 16xx, 17xx, 1Exx) and D000–DFFF (DDxx). About 12 000
        /// DIDs, roughly 20 min; it can be done in parts. Changing this starts the scan again.
        static let historyScanPlan: [(header: String, ranges: [ClosedRange<Int>])] = [
            ("7E0", [0x0300...0x04FF, 0x0000...0x02FF, 0x0500...0x0FFF, 0x1000...0x1FFF, 0xD000...0xDFFF]),
        ]
        /// Wait per DID while scanning (seconds). The PCM refuses a DID it doesn't have at once.
        static let historyScanTimeout: TimeInterval = 0.6
        /// DIDs asked per go, between two rounds of live data (a few seconds each), so Power Mode,
        /// reverse and the turn signals keep working during the scan.
        static let historyScanChunk = 48
        /// Seconds per DID for the time shown before the first scan (the scan measures the real one).
        static let historyScanSecondsPerDID = 0.1
        /// Entries in the PCM's history, and km per raw unit for 1-byte entries (the Torque preset for
        /// the SkyActiv-D shows each byte doubled; it read 30 km more than the dealer tool). 2-byte
        /// entries are read as km, 3- and 4-byte ones like 220434 (the whole value ·100/64000 km).
        static let historyEntries = 10
        static let historyKmPerUnit = 2.0
        /// A candidate needs at least `historyMinPlausible` of its 10 entries in this range (km) and at
        /// least 3 different values; the rest of what answers is only in the raw scan export.
        static let historyPlausibleKm: ClosedRange<Double> = 20...1500
        static let historyMinPlausible = 6
        /// Undecided candidates kept (best first); they're re-read when the DPF screen opens and after
        /// each regeneration, until one is confirmed.
        static let historyMaxCandidates = 24

        /// Data recorder (DPFRecorder, README "DPF data recorder"): while live data runs, screen open or not,
        /// a snapshot of the PCM's soot model and what feeds it every `recordInterval` seconds — every
        /// `recordIntervalDuringRegen` while a request bit of 220380 is on and for `recordFastAfterCountUp`
        /// after the count (220432) goes up — as one CSV row, exportable from the DPF screen. The fast tier is
        /// in every sample, the rest every `recordNormalInterval` / `recordSlowInterval` / once a drive. Off:
        /// nothing is read or recorded.
        static let recordEnabled = true
        /// The RPM / road speed read at most this far (seconds) from a reply count as "next to it"
        /// (EngineHealth lines oil pressure, idle and injector readings up with them).
        static let recordMarkMaxSeconds: TimeInterval = 4
        /// Measured on this car (5 Nov 2026): a read takes 50–100 ms, a live-data round 0.3–1.5 s between two
        /// goes, so a sample of everything (~70–90 reads) took 13–48 s and the old 30 s interval was the
        /// limit. Hence: a small fast tier every 10 s, the rest every 30 s, a smaller sweep and a bigger go.
        static let recordInterval: TimeInterval = 10
        static let recordNormalInterval: TimeInterval = 30
        static let recordIntervalDuringRegen: TimeInterval = 5
        static let recordFastAfterCountUp: TimeInterval = 1200
        /// The slow values (odometer, outside air, fuel level, oil dilution, community candidates…).
        static let recordSlowInterval: TimeInterval = 120
        /// The first sample after the engine ECU starts answering (seconds).
        static let recordFirstDelay: TimeInterval = 15
        /// How much is read per go between two live-data rounds, so Power Mode, reverse and the turn signals
        /// keep their pace: a single-frame read counts 1 (~50–100 ms), a reply of several frames 3. Every go
        /// starts with RPM (1), so the values can be lined up with the engine speed afterwards. 7: RPM and up
        /// to 6 single-frame reads, ~0.4–0.6 s, before live data has its next round (was 5).
        static let recordJobBudget = 7
        /// The DID sweep (raw only): DIDs per 30 s sample, the PCM blocks it goes through, the wait per DID.
        /// The first pass finds which DIDs exist (done on this car: 88 answer); after that only those are
        /// read, in turn (was 24 per sample).
        static let recordSweepPerSample = 8
        static let recordSweepRanges: [ClosedRange<Int>] = [0x0300...0x04FF, 0xDA00...0xDAFF]
        static let recordSweepTimeout: TimeInterval = 0.6
        /// DIDs the sweep found not there, asked again per sample, in turn (one can be missed while the PCM
        /// is busy; ~3 h of driving goes through all of them).
        static let recordSweepRecheck = 2
        /// Parked check (DPF screen, user-started; README "DPF data recorder"): this long, a sample every
        /// `recordCheckInterval` s (back to back in practice), up to `recordCheckJobBudget` per go (the car
        /// is parked, live data can wait), ended once the road speed passes `recordCheckMaxSpeed` km/h.
        static let recordCheckDuration: TimeInterval = 180
        static let recordCheckInterval: TimeInterval = 2
        static let recordCheckJobBudget = 12
        static let recordCheckMaxSpeed = 3.0
        /// A new CSV file past this size (bytes); the oldest ones go once all of them are over the total.
        static let recordMaxFileBytes = 20_000_000
        static let recordMaxTotalBytes = 60_000_000
        /// Kept for the export: events and drives; points of the current regeneration cycle for the rates.
        static let recordMaxEvents = 5000
        static let recordMaxDrives = 500
        static let recordCycleMaxPoints = 3000
        /// Events: PM_GEN falling by more than this (g/L) between two samples starts a new cycle;
        /// PM_ACC_DSD (044B) moving by this much (g/L) is noted.
        static let recordGenDrop = 1.0
        static let recordDsdJump = 1.0
        /// Fuel used (PID 5E) is only added up between samples at most this far apart (seconds).
        static let recordFuelGap: TimeInterval = 120

        /// PM_GEN growth (g/L): per 100 km over the last `rateWindowKm` of the cycle (at least `rateMinKm`),
        /// since the last regeneration once it's `rateMinSinceRegenKm` back, per hour over the last
        /// `rateWindowMinutes` of the drive (at least `rateMinMinutes`), per litre after `rateMinFuel` L.
        static let rateWindowKm = 10.0
        static let rateMinKm = 2.0
        static let rateMinSinceRegenKm = 3.0
        static let rateWindowMinutes = 10.0
        static let rateMinMinutes = 3.0
        static let rateMinFuel = 1.0
        /// A regeneration starts when PM_GEN reaches about this with the oil warm (owner logs on the
        /// FORScan forum; 6+ with the oil at 40–80 °C; the recorder's "0380 request" event shows this
        /// car's). Owners report a regeneration every 250–400 km in mixed driving: about
        /// `pmGenHealthyRate` g/L per 100 km at that trigger (an estimate, not a Mazda figure); from
        /// `pmGenRateHigh` the DPF screen flags it, once the last regeneration is `pmGenVerdictMinKm` back.
        static let pmGenTrigger = 5.6
        static let pmGenHealthyRate: ClosedRange<Double> = 1.5...2.5
        static let pmGenRateHigh = 3.5
        static let pmGenVerdictMinKm = 15.0
    }

    /// Engine health watch (EngineHealth, shown on the DPF screen): the values tied to fuel getting into the
    /// oil, each with a normal range and a "watch" level before the PCM's own fault codes. Fed by the DPF
    /// recorder's samples. "Mazda" = the SKYACTIV-D 2.2 workshop manual; the rest is Autobot's own guide.
    /// See README, "Engine health".
    enum EngineHealth {
        // Fuel in the oil: 03E1 OIL_DIL, the PCM's own estimate, g (FORScan's scale).
        static let oilDilutionWatch = 500.0
        static let oilDilutionHigh = 1_200.0
        /// Mazda: P252F "engine oil level too high" at 1,661 g, P253F "engine oil deteriorated" at 2,236 g
        /// (neither turns the check-engine light on).
        static let oilDilutionP252F = 1_661.0
        static let oilDilutionP253F = 2_236.0
        /// Regeneration log entries looked at (fuel added per regeneration, interrupted ones).
        static let regenEntriesUsed = 10
        // Oil pressure (0415 EOP). The PCM's own check (P253F) is 40 kPa below the value after the oil change
        // at 1,475–1,525 rpm with the oil at 87–88 °C. Here: standing at a hot idle (RPM read next to the
        // reply), where it is steady (~190–210 kPa on this car, Nov 2026; Mazda: about 184 kPa) and comes up at
        // every stop; at 1,500 rpm it climbs ~0.2 kPa per rpm, too steep to compare readings. The readings at
        // oilPressureHighRPM (~360–390 kPa here; Mazda: about 366 kPa at 4,000 rpm) are only shown.
        static let oilPressureRPM: ClosedRange<Double> = 700...900
        static let oilPressureHighRPM: ClosedRange<Double> = 1_700...3_500
        static let oilPressureOilTemp: ClosedRange<Double> = 85...95
        /// Readings in the median, and in the baseline (the first ones after an oil change); at least
        /// `oilPressureMinSamples` before it says anything.
        static let oilPressureSamples = 20
        static let oilPressureMinSamples = 5
        static let oilPressureDropWatch = 20.0
        static let oilPressureDropHigh = 30.0
        static let oilPressureDropP253F = 40.0
        /// Hot idle under this: low whatever the baseline.
        static let oilPressureLow = 150.0
        /// 0519 at most this far when the watch first sees it: the baseline counts as "after the oil change".
        static let oilPressureBaselineMaxKm = 1_000.0
        /// 0519 going back by more than this is an oil change.
        static let oilChangeSeenDropKm = 300.0
        static let oilChangeWatchKm = 7_500.0
        static let oilChangeHighKm = 10_000.0
        // Temperatures. Mazda: the thermostat starts opening at 80–84 °C and is fully open at 95 °C.
        static let coolantWarm = 80.0
        /// Driving this long (minutes on the move) and the coolant still under coolantWarm: slow warm-up.
        static let coolantWarmUpMinutes = 15.0
        /// Once warm, the coolant under this on the move (a thermostat stuck open cools too much), this many
        /// samples in a drive.
        static let coolantCruiseLow = 78.0
        static let coolantDipsWatch = 3
        /// Drives starting colder than this outside aren't judged for the warm-up.
        static let coolantMinAmbient = 0.0
        static let coolantHigh = 105.0
        /// Fuel boils out of the oil faster above about oilHot; a drive "got the oil hot" with oilHotMinutes
        /// there. This car's oil settles at 89–91 °C on a warm drive (Nov 2026).
        static let oilHot = 85.0
        static let oilHotMinutes = 10.0
        /// Drives in a row whose oil never reached oilWarm.
        static let oilWarm = 80.0
        static let coldDrivesWatch = 3
        static let coldDrivesHigh = 6
        /// After this long off: coolant and oil within coldStartSpreadWatch of each other, intake and outside
        /// air too, and the engine not colder than the air by that much (it may well be warmer: after 10 h on
        /// 6 Nov 2026 coolant / oil read 28 / 25 °C with the air at 19 °C, 47 s after the start).
        static let coldStartOffHours = 6.0
        /// …and the first coolant reading at most this (a drive without Autobot in between leaves it warm).
        static let coldStartMaxCoolant = 40.0
        static let coldStartSpreadWatch = 6.0
        static let coldStartSpreadHigh = 10.0
        /// The first samples of a drive (minutes) give its cold-start temperatures.
        static let firstSampleMinutes = 2.0
        // Fuel system. Mazda: rail about 40 MPa at idle, 80 MPa at 4,000 rpm; injector corrections about
        // ±0.3 mm³/stroke; idle 800 rpm (automatic) within 50 rpm of the target.
        static let railMinSamples = 10
        static let railGapWatch = 3.0
        static let railGapHigh = 6.0
        static let injectorCorrectionWatch = 0.8
        static let injectorCorrectionHigh = 1.5
        static let injectorLearningDriftWatch = 40.0
        static let injectorLearningDriftHigh = 80.0
        static let idleDeviationRPM = 50.0
        static let idleMinSamples = 5
        /// Standing (road speed 0) below this RPM counts as idle (idle speed, injector corrections).
        static let idleMaxRPM = 900.0
        /// Warm-idle readings of each injector correction kept (the item shows their median).
        static let injectorIdleReadings = 10
        static let idleOffShareWatch = 0.3
        static let idleOffShareHigh = 0.5
        // Regeneration. Owners report 250–400 km between regenerations in mixed driving.
        static let regenIntervalsAveraged = 5
        static let regenIntervalNormalKm = 250.0
        static let regenIntervalHighKm = 150.0
        static let interruptedWatch = 2
        static let interruptedHigh = 4
        /// PM_GEN per 100 km since the last regeneration, g/L (as AppConfig.DPF.pmGenHealthyRate / pmGenRateHigh).
        static let pmGenRateWatch = 2.5
        static let pmGenRateHigh = 3.5
        // Air: boost (PID 70, the MAP sensor) against the PCM's target, warm, on the move, at high load, in
        // this RPM range; the average gap over a drive. (MAF_DSD, 040C, isn't on this PCM.) Mazda gives no
        // figure. Only high load: at part load the PCM doesn't chase this target (5–6 Nov 2026: ~30 kPa short
        // at a steady 100 km/h, 228 kPa asked for with no fuel), at 60 % load and more it gets there.
        static let boostRPM: ClosedRange<Double> = 1_500...3_500
        static let boostMinLoad = 60.0
        static let boostMinSamples = 5
        static let boostGapWatch = 15.0
        // The DPF. Soot right after a regeneration (PM_ACC_DSD, PM_ACC in older log entries): Mazda "approx. 0"
        // after a complete one (P243C), ~0.1 typical (FORScan forum); more is ash or a clogged filter. Values
        // above sootAfterPlausibleMax are the old 042B misreading in log entries before 5 Nov 2026.
        static let sootAfterWatch = 0.3
        static let sootAfterHigh = 0.5
        static let sootAfterPlausibleMax = 5.0
        /// PM_ACC_DSD / PM_GEN while driving, judged from pressureVsModelMinGen g/L PM_GEN; Mazda's P243C check
        /// is 2× or more at 3,000 rpm.
        static let pressureVsModelMinGen = 1.0
        static let pressureVsModelWatch = 1.3
        static let pressureVsModelHigh = 2.0
        // Drives.
        static let drivesKept = 10
        static let movingSpeed = 5.0
        /// Under this road speed (km/h) the car counts as standing (hot-idle oil pressure, idle speed).
        static let standingSpeed = 3.0
        /// A longer gap between two samples counts as this many seconds (live data stopped meanwhile).
        static let maxSampleGap: TimeInterval = 300
    }

    /// Turn signals and hazard lights (TurnSignalFlash): flash in the current Power Mode colour while
    /// the indicators flash, above Power Mode and its switch flash. Heard on the car's HS-CAN bus:
    /// once a round the adapter listens for the indicator lamp frame (TurnSignals.swift, README
    /// "Turn signals").
    enum TurnSignals {
        /// The feature on or off. Off: the bus isn't listened to (live data as fast as before) and the
        /// dashboard row is hidden.
        static let enabled = true
        /// The HS-CAN frame with the indicator lamps: 0x09A ("lights"), about 10 times a second.
        static let frameID = "09A"
        /// Its byte with the lamp bits…
        static let lampByte = 2
        /// …and the bits that may be the left / right indicator. Two layouts are known and both are
        /// watched; only a bit that flashes counts, so the steady lights-on bit (0x08 in the first one)
        /// never does:
        ///   Mazda SkyActiv CAN database: 0x20 left, 0x10 right (0x08 lights on)
        ///   openpilot (CX-5 2017+):      0x04 left, 0x08 right
        static let leftBits: UInt8 = 0x24
        static let rightBits: UInt8 = 0x18
        /// Listen every this many rounds of live data. Each time adds a few hundred ms to the round;
        /// 2 halves that, but the mode-coloured flash then starts and ends up to a round later.
        static let everyRounds = 1
        /// Nothing flashing: listen this long, a bit more than the indicators' dark phase (about 0.35 s),
        /// so flashing indicators are always caught.
        static let idleListen: TimeInterval = 0.45
        /// Flashing: dark this long while listening means they've stopped. Must be longer than the dark
        /// phase plus one frame (0.1 s).
        static let offWindow: TimeInterval = 0.6
        /// A bit lit this long without a break is a steady light (lights on), not an indicator.
        static let steadyWindow: TimeInterval = 1.0
        /// No frame within this: none this round.
        static let firstFrameTimeout: TimeInterval = 0.4
        /// A look never lasts longer than this.
        static let maxListen: TimeInterval = 1.3
        /// Flashing ends this long after the last flash heard when nothing conclusive comes in (frames
        /// missing), so the turn-signal flash can't get stuck.
        static let holdLimit: TimeInterval = 3
        /// The first look of each connection lasts this long, with the CAN IDs shown, to check that the
        /// frame is there and that the adapter keeps other frames out while listening.
        static let checkListen: TimeInterval = 1.0
        /// This many looks in a row without the frame: it's taken as gone (logged), then listened for
        /// only every `retryRounds` rounds.
        static let missLimit = 5
        static let retryRounds = 30
    }

    /// Rain mode (RainMode): cyan gradient breathing while it rains as far as the windshield wipers say.
    /// Above the normal purple steady, below Power Mode and reverse.
    ///   lever OFF          -> off (the washer running the wipers with the lever OFF isn't rain)
    ///   lever LO or HI     -> on
    ///   lever AUTO / INT   -> on once the wipers really wipe, until `autoHold` after the last wipe
    /// The lever comes from the lights frame (AppConfig.TurnSignals.frameID, Wipers.swift), which is heard
    /// every round for the turn signals anyway: no extra adapter time. The wiping in AUTO / INT comes from
    /// the front body control module's wiper motor bit (found by the wiper finder), read only while the
    /// lever is in AUTO / INT.
    enum Rain {
        /// The feature on or off. Off: the wipers don't change the lighting, the motor is never read and
        /// the dashboard row is hidden.
        static let enabled = true
        /// A lever reading counts once it has held for this many readings in a row (one a round), so a
        /// quick MIST flick, or passing a position on the way to another, doesn't count.
        static let confirmReadings = 2
        /// Lever in AUTO / INT: rain mode stays on this long after the last wipe seen. Long enough to bridge
        /// the pauses of intermittent wiping in light rain and a wipe a reading misses (the motor is read
        /// every `motorPollEveryRounds` rounds, a wipe takes about a second); when the rain stops, rain mode
        /// ends this long after the last wipe. Coming from LO or HI into AUTO counts as a wipe.
        static let autoHold: TimeInterval = 90
        /// Lever in AUTO / INT: wipes within this long after the lever got there don't count. Moving the
        /// lever from OFF to AUTO wipes once (owner's manual), rain or not.
        static let autoSettle: TimeInterval = 5
        /// Lever in AUTO / INT: wipes within this long after the washer was last seen in use don't count.
        /// The washer wipes too (and a few more times after letting go), and the rain sensor may take the
        /// fluid on the glass for rain for a moment. Needs the washer's bit (lever check).
        static let washerHold: TimeInterval = 10
        /// Read the wiper motor bit every this many rounds while the lever is in AUTO / INT (a round with the
        /// turn-signal look takes about a second). Each read is three short adapter commands (ATSH726,
        /// ATCRA72E, the DID). 1 = every round: wipes are caught a little sooner, M / D a little later.
        static let motorPollEveryRounds = 2
        /// Don't read the wiper motor while the gear lever is in M (Power Mode shows red breathing instead)
        /// or R (reverse shows yellow): live data then stays as fast as without rain mode, and rain mode
        /// keeps its state until the lever is back in D.
        static let pauseMotorInPowerModeAndReverse = true
        /// Without a found wiper motor bit: false = AUTO / INT never counts as rain, true = it counts as rain
        /// as soon as the lever is there (like LO).
        static let autoCountsWithoutMotor = false

        /// Wiper finder, lever check: how long each step listens to the frame (about 15 frames).
        static let leverCheckListen: TimeInterval = 1.5
        /// Wiper finder, motor: where to look for the wiper motor bit. The front body control module (726,
        /// replies from 72E) drives the wiper LO and HI relays and reads the motor's auto-stop switch.
        /// C100–C1FF (the body status block on other Mazdas) and DA00–DAFF (58 DIDs answer on this car, live
        /// inputs among them: DA05 is the brake switch). The earlier wiper finder's scan of the same plan is
        /// reused; widen it if nothing is found (4000–40FF, DD00–DD0F…), the scan then runs again.
        static let motorScanPlan: [(header: String, ranges: [ClosedRange<Int>])] = [
            ("726", [0xC100...0xC1FF, 0xDA00...0xDAFF]),
        ]
        /// Wait per DID while scanning (seconds).
        static let motorScanTimeout: TimeInterval = 0.6
        /// Parked and Wiping read every scanned DID this many times (in separate passes), so values that
        /// change by themselves show up as unsteady.
        static let motorReadsPerSnapshot = 2
        /// Never the wiper motor, even if they slip into the scan: values that drift or count by themselves
        /// (Doors.ignoredDIDs: 12V battery, brake switch, a counter, the battery voltage — which sags while
        /// the motor runs, so it would look like a wiper bit).
        static let motorIgnoredDIDs: Set<String> = AppConfig.Doors.ignoredDIDs
        /// A trace reads the candidates' DIDs over and over for this long: lever OFF -> AUTO right at the
        /// start, one wipe of about a second, then parked again well before the end.
        static let traceDuration: TimeInterval = 8
        /// At most this many DIDs are traced (best first): each is read once per pass, so fewer DIDs time the
        /// wipe more finely (about 0.07 s per read).
        static let traceMaxDIDs = 10
        /// How a trace is judged: a wiper bit leaves its parked value within `moveWindow` s of "NOW" (the lever
        /// goes to AUTO right then), is back within `maxWipe` s (one wipe takes about a second), and stays
        /// parked for the last `settle` s. A slow counter bit or a drifting value comes and goes at other
        /// times, so it doesn't count.
        static let traceTiming = WiperMotorAnalysis.TraceTiming(settle: 1.0, moveWindow: 5.0, maxWipe: 2.0)
        /// Traces that should agree before the motor bit is taken as confirmed.
        static let tracesToConfirm = 2
    }

    /// Reverse (ReverseLight): yellow gradient breathing while the lever is in R, on Power Mode's level
    /// (Power Mode's switch flash, the turn signals, A/C flash and the door alert go above it).
    enum Reverse {
        /// The feature on or off. Off: R shows what Power Mode shows (purple steady) and the dashboard's
        /// Reverse row is hidden.
        static let enabled = true
        /// A lever reading (in R, or out of it) counts once it has held for this many readings in a row.
        /// The TCM's R code (7E1 221E12 = 3C) is unmistakable, so 1 is enough; 2 waits a round longer.
        static let confirmReadings = 1
    }

    enum Lamp {
        /// How many times to resend a mode command if the lamp reports a different mode afterwards.
        static let modeRetries = 2
        /// How many times to resend a packet the lamp answered with "busy" or "checksum error".
        static let nackRetries = 2
        /// Set the lamp's custom colour to the breathing colour (red in M, yellow in R) before gradient
        /// breathing. Some firmware breathes the custom colour instead of the gradient parameter (seen
        /// as purple breathing after the purple steady state). Set to false if this ever makes the
        /// breathing colourful instead.
        static let setColourBeforeBreathing = true
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
        /// Checkpoints, in %: the progress waits at `lampCheckpoint` until the lamp is connected, at
        /// `obdCheckpoint` until the OBD2 adapter is (Bluetooth), at `carAudioCheckpoint` until car audio
        /// (CarPlay) is; then it runs to 100 % and the dashboard opens.
        static let lampCheckpoint = 30.0
        static let obdCheckpoint = 60.0
        static let carAudioCheckpoint = 90.0
        /// Progress speed in % per second.
        /// 0 → 30 % always runs, even with nothing connected (faster if the lamp is already there);
        /// 30 → 60 % needs the lamp; 60 → 90 % the OBD2 adapter; 90 → 100 % car audio.
        static let rateToLamp = 7.0
        static let rateToLampReady = 14.0
        static let rateToOBD = 14.0
        static let rateToCarAudio = 14.0
        static let rateToFull = 20.0
        /// Within this many % of a checkpoint where it has to wait the progress slows down, so it eases
        /// in instead of stopping dead.
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
        /// Engine sound volume 0…1, on top of the phone's / car's own volume. Kept low so the
        /// start-up doesn't startle when the car's volume is still turned up from music
        /// (0.15 ≈ -16 dB; 1.0 = full, 0.3 ≈ -10 dB).
        static let engineVolume: Float = 0.15
    }

    enum Listening {
        /// The reply is recognised in this language only: Mandarin (Simplified Chinese).
        static let locale = "zh-CN"
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
        /// The shortcut that starts QQ Music. It only handles the music; Autobot opens Google
        /// Maps itself once the shortcut comes back. Runs only when no music was playing when
        /// the car connected; if iOS refuses to open Shortcuts, Autobot opens Google Maps directly
        /// (then without music).
        ///   1. QQ音乐 - 最近播放 (or 继续播放)
        ///   2. 打开URL - autobot://maps   (back to Autobot, which then opens Google Maps)
        static let shortcutName = "最近播放的歌"
        /// How long to wait for the shortcut to come back (autobot://maps) before giving up on Maps.
        static let returnTimeout: TimeInterval = 20
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
        static let dpfRegenStarted = "DPF regeneration started"
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
