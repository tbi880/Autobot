// RainMode.swift
// Cyan gradient breathing while it rains as far as the windshield wipers say. Above the normal purple
// steady, below Power Mode and reverse: in M the lamp breathes red as usual, in R yellow, and back in D
// it's cyan again while it still rains.
//
//   lever OFF          -> not rain (the washer running the wipers with the lever OFF isn't rain either)
//   lever LO or HI     -> rain, as soon as two readings in a row agree (so a MIST flick doesn't count)
//   lever AUTO / INT   -> rain once the wipers really wipe, and until they have stayed parked for
//                         AppConfig.Rain.autoHold (30 s) with no next wipe seen. Only time the motor was
//                         really watched counts: each parked reading adds the time since the reading
//                         before, at most AppConfig.Rain.wipeLength (a wipe that started longer ago than
//                         that could have come and gone unseen), and a stretch without readings adds
//                         nothing. Not counted: the one wipe moving the lever into AUTO makes
//                         (autoSettle) and the washer's wipes (washerHold). Coming from LO or HI it stays
//                         on (that counts as a wipe).
//
// Where it comes from (Wipers.swift):
//   - the lever: frame 09A, decoded with the lever layout (built in, or the one the lever check saved).
//     OBDAdapter listens to that frame every round for the turn signals anyway (`lightsFrame`), so this
//     costs no adapter time;
//   - the wiping in AUTO / INT: the front body control module's wiper motor bit (the one the wiper finder
//     found), which OBDAdapter reads only while the lever is in AUTO / INT, twice a round and after work
//     between rounds (AppConfig.Rain.motorReadsPerRound, motorReadAfterJobs), and not at all while the
//     lever is in M or R
//     (AppConfig.Rain.pauseMotorInPowerModeAndReverse): the lamp shows Power Mode / reverse then anyway, and
//     live data stays as fast as without rain mode. Without a found motor bit, AUTO / INT doesn't count
//     (AppConfig.Rain.autoCountsWithoutMotor).
// No frame (live data stopped) ends it. The dashboard's Rain button stands in for all of it.
//
// The breathing is a LightingArbiter request from `.rain`, between the normal purple (`.base`) and Power
// Mode (`.powerMode`); reverse, the turn signals, the A/C flash and the door alert go above it too.

import Combine
import Foundation

private typealias Tuning = AppConfig.Rain

final class RainMode: ObservableObject {

    /// True while the lamp breathes cyan (the car's wipers, or a test).
    @Published private(set) var isOn = false
    /// The wiper lever as the latest frame shows it; nil while unknown (no frame, or a code that isn't a
    /// lever position).
    @Published private(set) var lever: WiperLever?
    /// The lever once it has held (AppConfig.Rain.confirmReadings readings); what rain mode goes by.
    @Published private(set) var confirmed: WiperLever?
    /// The washer in use in the latest frame (as far as its bit is known).
    @Published private(set) var washing = false
    /// It rains as far as the car's wipers say.
    @Published private(set) var carRaining = false
    /// Lever in AUTO / INT and the wipers wiped, and haven't stayed parked for AppConfig.Rain.autoHold since.
    @Published private(set) var wipingInAuto = false
    /// Lever in AUTO / INT, after a wipe: how long the wipers have been watched parked since (watched time,
    /// see AppConfig.Rain.wipeLength); rain mode ends at AppConfig.Rain.autoHold. 0 while wiping.
    @Published private(set) var parkedFor: TimeInterval = 0
    /// Lever in AUTO / INT but the motor isn't read right now: the lever is in M or R.
    @Published private(set) var motorPaused = false
    /// True while the test button is in charge.
    @Published private(set) var simulated = false

    /// How the lever is read from frame 09A: the built-in layout, or the one the lever check saved.
    var leverLayout = WiperLeverLayout.builtIn {
        didSet {
            guard leverLayout != oldValue else { return }
            candidate = nil
            candidateCount = 0
            reportedCodes = []
        }
    }
    /// The front body control module's wiper motor bit (found by the wiper finder); nil = not known, and
    /// then AUTO / INT never counts as rain (unless AppConfig.Rain.autoCountsWithoutMotor).
    var motorSignal: WiperMotorSignal? {
        didSet { updateMotorPolling() }
    }

    /// Changes, for the dashboard log.
    var onLog: ((String) -> Void)?

    private let obd: OBDAdapter
    private let lighting: LightingArbiter
    private var candidate: WiperLever?               // the lever in the latest readings…
    private var candidateCount = 0                   // …and in how many in a row
    private var autoSeen: Date?                      // the first reading of AUTO / INT this time
    private var enteredAuto: Date?                   // the lever got to AUTO / INT (as far as we can tell)
    private var lastWasher: Date?                    // the washer was last seen in use
    private var lastRainWipe: Date?                  // the wipers last wiped in AUTO / INT (not for the washer)
    private var lastParkedRead: Date?                // the latest motor reading, if it showed them parked
    private var motorMisses = 0                      // motor reads in a row without a usable reply
    private var selector: ELM327.Selector?           // the gear lever, for pausing the motor in M / R
    private var reportedCodes: Set<String> = []      // frame codes already logged as unknown
    private var subscriptions = Set<AnyCancellable>()

    init(obd: OBDAdapter, lighting: LightingArbiter) {
        self.obd = obd
        self.lighting = lighting
        obd.$lightsFrame
            .sink { [weak self] frame in self?.handle(frame) }
            .store(in: &subscriptions)
        obd.$wiperMotorRunning
            .sink { [weak self] running in self?.motorReading(running) }
            .store(in: &subscriptions)
        obd.$sample
            .sink { [weak self] sample in self?.selectorChanged(sample?.selector) }
            .store(in: &subscriptions)
    }

    /// Debug: as if the wipers were switched on; the same button again hands back to the car.
    func simulate() {
        simulated.toggle()
        onLog?("Rain test: " + (simulated ? "wipers on" : "back to the car's wipers"))
        update()
    }

    /// For the screens: what the AUTO / INT side is doing now.
    var autoStatus: String {
        if motorSignal == nil {
            return Tuning.autoCountsWithoutMotor ? "AUTO counts at once (no motor bit)"
                : "motor bit not found yet: AUTO doesn't count (Wiper finder)"
        }
        if motorPaused { return "motor not read in M / R" }
        guard wipingInAuto else { return "waiting for a wipe" }
        if obd.wiperMotorRunning == true { return "wiping" }
        return String(format: "parked %.0f of %.0f s", parkedFor, Tuning.autoHold)
    }

    // MARK: Readings

    /// One reading of frame 09A (every round); nil = not heard, no live data.
    private func handle(_ frame: [UInt8]?) {
        let now = Date()
        guard let frame else {
            if lever != nil { lever = nil }
            if washing { washing = false }
            candidate = nil
            candidateCount = 0
            confirmed = nil
            autoSeen = nil
            enteredAuto = nil
            lastRainWipe = nil
            resetParked()
            updateMotorPolling()
            evaluate(now)
            return
        }
        let reading = leverLayout.lever(in: frame)
        if reading != lever { lever = reading }
        let washingNow = leverLayout.isWashing(frame)
        if washingNow != washing { washing = washingNow }
        if washingNow { lastWasher = now }

        if let reading, !washingNow {                    // while washing the lever reading is no news
            if reading == candidate {
                candidateCount += 1
            } else {
                candidate = reading
                candidateCount = 1
                autoSeen = reading == .auto ? now : nil
            }
            if candidateCount >= max(Tuning.confirmReadings, 1), reading != confirmed {
                leverMoved(from: confirmed, to: reading, frame: frame, at: now)
            }
        } else if reading == nil, !washingNow {
            reportUnknown(frame)
        }
        updateMotorPolling()
        evaluate(now)
    }

    /// The lever has held in a new position.
    private func leverMoved(from old: WiperLever?, to new: WiperLever, frame: [UInt8], at now: Date) {
        confirmed = new
        onLog?("Wipers: lever \(new.label) · 09A " + leverLayout.placeLabel + " = " + leverLayout.codeText(frame))
        resetParked()
        guard new == .auto else {
            enteredAuto = nil
            lastRainWipe = nil
            return
        }
        enteredAuto = autoSeen ?? now
        // From LO or HI it rained a moment ago: carry on as after a wipe, so the lamp stays cyan.
        lastRainWipe = (old == .low || old == .high) ? now : nil
    }

    /// The parked count starts again from nothing (a wipe, the lever moved, back from M / R).
    private func resetParked() {
        lastParkedRead = nil
        motorMisses = 0
        if parkedFor != 0 { parkedFor = 0 }
    }

    /// One reading of the wiper motor bit (about every second while the lever is in AUTO / INT); nil = no
    /// usable reply, or not read any more.
    private func motorReading(_ running: Bool?) {
        guard confirmed == .auto, motorSignal != nil, !motorPaused else { return }
        let now = Date()
        switch running {
        case nil:
            // Not watched: the stretch up to the next reply adds nothing to the parked count.
            lastParkedRead = nil
            motorMisses += 1
        case true?:
            motorMisses = 0
            if let enteredAuto, now.timeIntervalSince(enteredAuto) < Tuning.autoSettle { return }  // moving the lever wipes once
            if let lastWasher, now.timeIntervalSince(lastWasher) < Tuning.washerHold { return }    // the washer's wipes
            if !wipingInAuto { onLog?("Wipers: wiping in AUTO / INT (" + (obd.wiperMotorRaw ?? "") + ")") }
            lastRainWipe = now
            resetParked()                            // the 30 s start again once they're parked
        case false?:
            motorMisses = 0
            // Parked: watched since the reading before, as far as a wipe starting meanwhile would still
            // show now (wipeLength). The first parked reading after a wipe is where the count starts.
            if lastRainWipe != nil, let last = lastParkedRead {
                parkedFor += min(now.timeIntervalSince(last), Tuning.wipeLength)
            }
            lastParkedRead = now
        }
        evaluate(now)
    }

    /// The gear lever, for pausing the motor reads in M and R.
    private func selectorChanged(_ newSelector: ELM327.Selector?) {
        guard let newSelector else { return }                    // a round without the TCM: no news
        guard newSelector != selector else { return }
        selector = newSelector
        updateMotorPolling()
    }

    /// The motor bit is read only while the lever is (or is about to be) in AUTO / INT, and not in M or R.
    private func updateMotorPolling() {
        let inAuto = confirmed == .auto || candidate == .auto
        let overridden = Tuning.pauseMotorInPowerModeAndReverse && isLampOverridden
        let wanted = (inAuto && !overridden) ? motorSignal : nil
        let paused = inAuto && overridden && motorSignal != nil
        if paused != motorPaused {
            motorPaused = paused
            // Back from M / R while it rained: the wipes weren't watched meanwhile (rain mode was kept as it
            // was), so the parked count starts again from now.
            if !paused, wipingInAuto {
                lastRainWipe = Date()
                resetParked()
            }
        }
        if obd.wiperMotorSignal != wanted { obd.wiperMotorSignal = wanted }
    }

    /// Power Mode (M, when it follows the selector) or reverse shows instead of rain mode.
    private var isLampOverridden: Bool {
        switch selector {
        case .reverse?:
            return AppConfig.Reverse.enabled
        case .manual?:
            if case .manualShift = AppConfig.PowerMode.trigger { return true }
            return false
        default:
            return false
        }
    }

    private func evaluate(_ now: Date) {
        let autoWiping: Bool
        var why: String?                                     // why AUTO / INT stopped counting, for the log
        if confirmed != .auto {
            autoWiping = false
        } else if motorSignal == nil {
            autoWiping = Tuning.autoCountsWithoutMotor
        } else if motorPaused {
            autoWiping = wipingInAuto                        // not watched in M / R: stays as it was
        } else if lastRainWipe == nil {
            autoWiping = false
        } else if motorMisses >= max(Tuning.motorMissLimit, 1) {
            autoWiping = false
            why = "the wiper motor bit stopped answering"
        } else {
            autoWiping = parkedFor < Tuning.autoHold        // still wiping, or parked for less than 30 s
            why = "wipers parked for \(Int(Tuning.autoHold)) s with no next wipe"
        }
        if autoWiping != wipingInAuto {
            wipingInAuto = autoWiping
            if !autoWiping {                                 // done with this rain: wait for a new wipe
                lastRainWipe = nil
                resetParked()
            }
        }
        carChanged(raining: confirmed == .low || confirmed == .high || autoWiping, why: why)
    }

    /// The car's wipers say rain or not; that takes over from a test.
    private func carChanged(raining: Bool, why: String?) {
        guard raining != carRaining else { return }
        carRaining = raining
        simulated = false
        let wipers = "wipers " + (confirmed?.label ?? "unknown")
        if raining {
            onLog?("Rain mode: on (" + (confirmed == .auto ? "AUTO / INT, the wipers are wiping" : wipers) + ")")
        } else if confirmed == .auto {
            onLog?("Rain mode: off (AUTO / INT, " + (why ?? "no wipe") + ")")
        } else {
            onLog?("Rain mode: off (" + wipers + ")")
        }
        update()
    }

    /// A frame whose lever bits are no known position: logged once per value, so a layout that doesn't fit
    /// this car shows in the log (a short one between two positions is normal).
    private func reportUnknown(_ frame: [UInt8]) {
        let code = leverLayout.codeText(frame)
        guard !reportedCodes.contains(code), reportedCodes.count < 8 else { return }
        reportedCodes.insert(code)
        onLog?("Wipers: 09A " + leverLayout.placeLabel + " = " + code
               + " is no known lever position (between two, or run the lever check) · " + Wipers.hex(frame))
    }

    private func update() {
        let on = Tuning.enabled && (simulated || carRaining)
        guard on != isOn else { return }
        isOn = on
        if on {
            lighting.request(.cyanBreathing, from: .rain)
        } else {
            lighting.clear(.rain)                     // back to the normal purple (or Power Mode above)
        }
    }
}
