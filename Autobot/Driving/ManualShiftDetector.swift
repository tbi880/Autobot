// ManualShiftDetector.swift
// Works out whether you are shifting yourself (M: lever pushed right from D) and holding the
// revs, from what standard OBD2 offers: engine RPM, road speed and the accelerator pedal (or the
// engine load if the car doesn't report the pedal). OBD2 has no "M" value, so this looks for what
// the automatic never does on its own in D:
//
//   1. Revs above what D allows for this much pedal, for a second. D shifts up early (the CX-5
//      2.2D turns about 2000 r/min at 110 km/h in 6th), so e.g. 2600 r/min with the foot off,
//      3000 at 40 % pedal or 4800 at full throttle mean the gear is being held. Past 4800 a
//      moment is enough: D shifts up before that even when floored.
//   2. A downshift with the foot off, at 25 km/h or more, that lands at 1800 r/min or more
//      (engine braking). Coasting in D, the gearbox only shifts down at low revs.
//
// The gear comes from RPM ÷ speed, which is fixed in each gear: the gearbox ratios with top gear
// set from 2000 r/min at 110 km/h, fine-tuned while cruising. If the car reports PID A4 the gear
// is taken from there instead.
// Manual stays on while the revs stay above 2500 r/min and ends after 10 s below that.
// All values: AppConfig.Manual. PowerModeController takes it from there (buffer zone,
// announcement, lighting), unchanged.

import Combine
import Foundation

private typealias Tuning = AppConfig.Manual

final class ManualShiftDetector: ObservableObject, PowerModeTrigger {

    /// .redBreathing while manual shifting is detected (Power Mode), otherwise .purpleSteady.
    @Published private(set) var state: LampState = .purpleSteady
    /// Current gear 1…6; nil while unknown (stopped, shifting, torque converter slipping).
    @Published private(set) var gear: Int?
    /// True when `gear` comes from the car (PID A4 / DID 1E1F), false when worked out from RPM ÷ speed.
    @Published private(set) var gearFromCar = false
    /// The real gear-selector lever (P/R/N/D/M) from the car, when it reports it (DID 1E23); nil
    /// otherwise. R is exposed here too (the reverse lighting, ReverseLight, reads the lever straight
    /// from the samples, without this debounce).
    @Published private(set) var selector: ELM327.Selector?
    /// True while Power Mode follows the car's real M/D selector; false while it's worked out from
    /// RPM/speed/pedal (the car doesn't report the selector).
    @Published private(set) var usingRealSelector = false
    /// What made it decide on manual shifting, for the dashboard and the log.
    @Published private(set) var reason: String?
    /// Engine r/min per km/h in top gear, fine-tuned while cruising.
    @Published private(set) var topGearRatio: Double

    /// Called only when `state` actually changes.
    var onStateChange: ((LampState) -> Void)?
    /// Detection messages for the dashboard log.
    var onLog: ((String) -> Void)?

    private var subscription: AnyCancellable?
    private var candidateGear: Int?               // gear in the latest reading…
    private var candidateCount = 0                // …and in how many readings in a row
    private var lastGear: (gear: Int, time: Date)?
    private var revsHighSince: Date?
    private var selectorCandidate: ELM327.Selector?
    private var selectorCount = 0
    private var lastManualSign: Date?
    private var recent: [OBDSample] = []          // the last few seconds, for the speed trend
    private var lastSaved = Date.distantPast

    private static let ratioKey = "ManualShiftDetector.topGearRatio"

    init(obd: OBDAdapter) {
        let saved = UserDefaults.standard.double(forKey: Self.ratioKey)
        topGearRatio = saved > 0 ? saved : Tuning.topGearRpmPerKmh
        subscription = obd.$sample.sink { [weak self] sample in self?.handle(sample) }
    }

    // MARK: Readings

    private func handle(_ sample: OBDSample?) {
        guard let sample else {                    // readings stopped: keep the state
            candidateGear = nil
            candidateCount = 0
            gear = nil
            revsHighSince = nil
            selectorCandidate = nil
            selectorCount = 0
            recent.removeAll()
            return
        }
        recent.append(sample)
        recent.removeAll { sample.time.timeIntervalSince($0.time) > Tuning.trendWindow }

        updateGear(sample)

        if let reported = sample.selector {
            usingRealSelector = true
            applySelector(reported, sample)        // the car tells us M/D directly
        } else {
            usingRealSelector = false
            selectorCandidate = nil
            selectorCount = 0
            checkRevs(sample)                      // no selector: work M out from the numbers
            learnTopGear(sample)
            checkCalm(sample)
        }
    }

    // MARK: Real selector (DID 1E23)

    /// Drive Power Mode straight from the car's gear-selector lever: M -> red breathing, anything
    /// else -> purple steady. A value counts once it has held for `selectorConfirmReadings` readings,
    /// so a single garbled byte doesn't flip the lamp; an unmapped byte leaves the state as it is.
    private func applySelector(_ reported: ELM327.Selector, _ s: OBDSample) {
        if reported == selectorCandidate {
            selectorCount += 1
        } else {
            selectorCandidate = reported
            selectorCount = 1
        }
        guard selectorCount >= Tuning.selectorConfirmReadings else { return }
        selector = reported
        if case .unknown = reported { return }     // unrecognised code: don't change Power Mode
        setManual(reported.isManual, reason: "selector in \(reported.label) (from the car)", s)
    }

    // MARK: Gear

    /// A gear counts once it is the same in two readings in a row; a new gear seen within a few
    /// seconds of the old one is a shift.
    private func updateGear(_ s: OBDSample) {
        let reading = s.gear ?? estimatedGear(rpm: s.rpm, speed: s.speed)
        gearFromCar = s.gear != nil
        if reading == candidateGear {
            candidateCount += 1
        } else {
            candidateGear = reading
            candidateCount = 1
        }
        guard candidateCount >= Tuning.gearConfirmReadings else { return }
        gear = reading
        guard let reading else { return }
        if let last = lastGear, last.gear != reading, s.time.timeIntervalSince(last.time) <= Tuning.shiftWindow {
            shifted(from: last.gear, to: reading, s)
        }
        lastGear = (reading, s.time)
    }

    /// The gear whose ratio fits RPM ÷ speed best, if one fits within the tolerance.
    private func estimatedGear(rpm: Double, speed: Double?) -> Int? {
        guard let speed, speed >= Tuning.minSpeedForGear,
              let top = Tuning.gearRatios.last, top > 0 else { return nil }
        let measured = rpm / speed
        var best: (gear: Int, error: Double)?
        for (index, ratio) in Tuning.gearRatios.enumerated() {
            let error = abs(measured / (topGearRatio * ratio / top) - 1)
            if error < (best?.error ?? .infinity) { best = (index + 1, error) }
        }
        guard let best, best.error <= Tuning.gearTolerance else { return nil }
        return best.gear
    }

    /// Cruising in top gear: nudge the top-gear value toward what is measured, so tyre size and
    /// speed-sensor differences stop mattering. Saved for the next drive.
    private func learnTopGear(_ s: OBDSample) {
        guard Tuning.learnTopGear, !gearFromCar, let speed = s.speed, speed >= Tuning.learnMinSpeed,
              gear == Tuning.gearRatios.count, candidateGear == gear else { return }
        let measured = s.rpm / speed
        guard abs(measured / topGearRatio - 1) <= Tuning.gearTolerance else { return }
        topGearRatio += (measured - topGearRatio) * Tuning.learnRate
        if s.time.timeIntervalSince(lastSaved) > 30 {
            UserDefaults.standard.set(topGearRatio, forKey: Self.ratioKey)
            lastSaved = s.time
        }
    }

    // MARK: Rules

    /// Rule 1: revs above what D allows for this much pedal, for `revHoldTime` (only
    /// `overRevHoldTime` once past `overRevRPM`, where D never goes).
    private func checkRevs(_ s: OBDSample) {
        let ceiling = Self.dModeCeiling(demand: s.demand)
        guard let speed = s.speed, speed >= Tuning.minSpeed, s.rpm > ceiling else {
            revsHighSince = nil
            return
        }
        let since = revsHighSince ?? s.time
        revsHighSince = since
        let hold = s.rpm >= Tuning.overRevRPM ? Tuning.overRevHoldTime : Tuning.revHoldTime
        guard s.time.timeIntervalSince(since) >= hold else { return }
        manualSign(s, reason: "\(Int(s.rpm)) r/min\(gearText) at \(Self.pedalText(s.demand)); D shifts up by \(Int(ceiling))")
    }

    /// Rule 2: a downshift with the foot off at speed that lands well above idle (engine braking).
    private func shifted(from: Int, to: Int, _ s: OBDSample) {
        guard to < from, let speed = s.speed, speed >= Tuning.engineBrakeMinSpeed,
              s.rpm >= Tuning.engineBrakeRPM, footOff(s) else { return }
        manualSign(s, reason: "shifted down \(from)→\(to) with the foot off at \(Int(speed)) km/h, \(Int(s.rpm)) r/min")
    }

    /// Foot off the accelerator: from the pedal (or the engine load) when the car reports it,
    /// otherwise from the car slowing down.
    private func footOff(_ s: OBDSample) -> Bool {
        if let demand = s.demand { return demand <= Tuning.footOffDemand }
        guard let before = recent.first?.speed, let now = s.speed else { return false }
        return now - before <= -Tuning.slowingDown
    }

    private func manualSign(_ s: OBDSample, reason: String) {
        lastManualSign = s.time
        setManual(true, reason: reason, s)
    }

    /// Switch Power Mode on (red breathing) or off (purple steady), announcing and logging only on a
    /// real change. Shared by the heuristic and the real-selector path.
    private func setManual(_ on: Bool, reason: String, _ s: OBDSample) {
        let target: LampState = on ? .redBreathing : .purpleSteady
        guard state != target else { return }
        self.reason = reason
        state = target
        onLog?("Manual: " + reason)
        onStateChange?(target)
    }

    /// Back to D-style driving once the revs have stayed low for `calmTime` (heuristic path only).
    private func checkCalm(_ s: OBDSample) {
        guard state == .redBreathing else { return }
        if s.rpm > Tuning.calmRPM { lastManualSign = s.time }      // still revving: stay manual
        guard let last = lastManualSign, s.time.timeIntervalSince(last) >= Tuning.calmTime else { return }
        setManual(false, reason: "revs at or below \(Int(Tuning.calmRPM)) r/min for \(Int(Tuning.calmTime)) s, back to D-style driving", s)
    }

    // MARK: Helpers

    /// The highest RPM D settles at for this much pedal (AppConfig.Manual.dModeCeiling, straight
    /// lines between the points). Without pedal data only the full-throttle value counts.
    static func dModeCeiling(demand: Double?) -> Double {
        let points = Tuning.dModeCeiling
        guard let first = points.first, let last = points.last else { return 4800 }
        guard let demand else { return last.rpm }
        if demand <= first.demand { return first.rpm }
        for (a, b) in zip(points, points.dropFirst()) where demand <= b.demand {
            return a.rpm + (b.rpm - a.rpm) * (demand - a.demand) / max(b.demand - a.demand, 1)
        }
        return last.rpm
    }

    static func pedalText(_ demand: Double?) -> String {
        demand.map { "\(Int($0)) % pedal" } ?? "unknown pedal"
    }

    private var gearText: String {
        gear.map { " in gear \($0)" } ?? ""
    }
}
