// RainMode.swift
// Cyan gradient breathing while it rains as far as the windshield wipers say, not when they only run
// because the washer is used. Above the normal purple steady, below Power Mode: in M the lamp breathes
// red as usual, and back in D it's cyan again while it still rains.
//
//   lever LO or HI     -> rain mode at once (the wipers run all the time)
//   lever AUTO         -> rain mode once the rain sensor makes the wipers wipe, and until
//                         AppConfig.Rain.autoHold after the last wipe. The wipe moving the lever to AUTO
//                         makes doesn't count (autoSettle), nor do the washer's (washerHold). Coming from
//                         LO or HI it stays on (that counts as a wipe).
//   lever OFF          -> not rain, washing or not
//
// The lever comes from the lights frame on HS-CAN (OBDAdapter.lightsFrame, one reading per round),
// decoded with the bits WiperFinder learned, or the built-in guess until then (Wipers.swift,
// AppConfig.Rain); the washer has its own bits and never moves the lever. A lever position counts once it
// has held for AppConfig.Rain.confirmReadings readings, so a quick MIST flick doesn't start it; a frame
// that fits no known position changes nothing; the frame going missing (live data stopped) ends it.
// Whether the wipers really wipe comes from the front body control module (726), which drives them:
// WiperFinder learns that bit, and OBDAdapter reads it every round while the lever is in AUTO
// (wiperMotorSignals -> wiperMotorRunning). Until it's learned, AUTO never counts. The dashboard's Rain
// button stands in for all of it.
//
// The breathing is a LightingArbiter request from `.rain`, between the normal purple (`.base`) and
// Power Mode (`.powerMode`); reverse, the turn signals, the A/C flash and the door alert go above it too.

import Combine
import Foundation

private typealias Tuning = AppConfig.Rain

final class RainMode: ObservableObject {

    /// True while the lamp breathes cyan (the car's wipers, or a test).
    @Published private(set) var isOn = false
    /// The wiper lever as the latest frame shows it; nil while unknown.
    @Published private(set) var lever: WiperSignal.Position?
    /// The washer in use in the latest frame (as far as its bits are known).
    @Published private(set) var washing = false
    /// It rains as far as the car's wipers say (confirmed).
    @Published private(set) var carRaining = false
    /// Lever in AUTO and the wipers wiped within AppConfig.Rain.autoHold.
    @Published private(set) var wipingInAuto = false
    /// True while the test button is in charge.
    @Published private(set) var simulated = false

    /// The lever and washer bits in use: learned by WiperFinder, or the built-in guess.
    var signal = Tuning.builtIn {
        didSet {
            candidate = nil
            candidateCount = 0
        }
    }
    /// The front body control module bits that say the wipers are wiping (learned by WiperFinder); empty
    /// = not known, and then AUTO never counts as rain.
    var motorSignals: [BitSignal] = [] {
        didSet { updateMotorPolling() }
    }

    /// Changes, for the dashboard log.
    var onLog: ((String) -> Void)?

    private let obd: OBDAdapter
    private let lighting: LightingArbiter
    private var candidate: WiperSignal.Position?     // the lever in the latest readings…
    private var candidateCount = 0                   // …and in how many in a row
    private var confirmed: WiperSignal.Position?     // the lever, once it has held
    private var enteredAuto: Date?                   // the lever got to AUTO (confirmed)
    private var lastWasher: Date?                    // the washer was last seen in use
    private var lastRainWipe: Date?                  // the wipers last wiped in AUTO (not for the washer)
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
    }

    /// Debug: as if the wipers were switched on; the same button again hands back to the car.
    func simulate() {
        simulated.toggle()
        onLog?("Rain test: " + (simulated ? "wipers on" : "back to the car's wipers"))
        update()
    }

    // MARK: Readings

    /// One reading of the lights frame (every round); nil = not heard, no live data.
    private func handle(_ frame: [UInt8]?) {
        let now = Date()
        guard let frame else {
            if lever != nil { lever = nil }
            if washing { washing = false }
            candidate = nil
            candidateCount = 0
            confirmed = nil
            enteredAuto = nil
            lastRainWipe = nil
            updateMotorPolling()
            evaluate(now)
            return
        }
        let position = signal.lever(in: frame)
        if position != lever { lever = position }
        let washingNow = signal.isWashing(frame)
        if washingNow != washing { washing = washingNow }
        if washingNow { lastWasher = now }
        if let position {                                // a frame that fits nothing: no news
            if position == candidate {
                candidateCount += 1
            } else {
                candidate = position
                candidateCount = 1
            }
            if candidateCount >= max(Tuning.confirmReadings, 1), position != confirmed {
                leverMoved(from: confirmed, to: position, at: now)
            }
        }
        updateMotorPolling()
        evaluate(now)
    }

    /// The lever has held in a new position.
    private func leverMoved(from old: WiperSignal.Position?, to new: WiperSignal.Position, at now: Date) {
        confirmed = new
        guard new == .auto else {
            enteredAuto = nil
            lastRainWipe = nil
            return
        }
        enteredAuto = now
        // From LO or HI it rained a moment ago: carry on as after a wipe, so the lamp stays cyan.
        lastRainWipe = (old == .low || old == .high) ? now : nil
    }

    /// One reading of the wiper motor bits (every round while the lever is in AUTO).
    private func motorReading(_ running: Bool?) {
        guard running == true, confirmed == .auto else { return }
        let now = Date()
        if let enteredAuto, now.timeIntervalSince(enteredAuto) < Tuning.autoSettle { return }  // moving the lever wipes once
        if let lastWasher, now.timeIntervalSince(lastWasher) < Tuning.washerHold { return }    // the washer's wipes
        lastRainWipe = now
        evaluate(now)
    }

    /// The motor bits are only read while the lever is (or is about to be) in AUTO.
    private func updateMotorPolling() {
        let wanted = (confirmed == .auto || candidate == .auto) ? motorSignals : []
        if obd.wiperMotorSignals != wanted { obd.wiperMotorSignals = wanted }
    }

    private func evaluate(_ now: Date) {
        let autoWiping = confirmed == .auto
            && lastRainWipe.map { now.timeIntervalSince($0) < Tuning.autoHold } == true
        if autoWiping != wipingInAuto { wipingInAuto = autoWiping }
        carChanged(raining: confirmed == .low || confirmed == .high || autoWiping)
    }

    /// The car's wipers say rain or not; that takes over from a test.
    private func carChanged(raining: Bool) {
        guard raining != carRaining else { return }
        carRaining = raining
        simulated = false
        let lever = "wipers " + (confirmed?.label ?? "unknown")
        if raining {
            onLog?("Rain mode: " + (confirmed == .auto ? "AUTO, the wipers are wiping" : lever))
        } else {
            onLog?("Rain mode: off (" + (confirmed == .auto ? "AUTO, no wipe for \(Int(Tuning.autoHold)) s" : lever) + ")")
        }
        update()
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
