// ManualShiftDetector.swift
// Power Mode follows the selector reported by the car: M = red breathing, every other known
// position = Power Mode off. There is no RPM/speed/pedal fallback; if the car doesn't report a
// selector or M flag, use MFinder to learn the signal.

import Combine

final class ManualShiftDetector: ObservableObject, PowerModeTrigger {

    /// .redBreathing while the lever is in M; otherwise .purpleSteady.
    @Published private(set) var state: LampState = .purpleSteady
    /// The real gear-selector lever (P/R/N/D/M), when the car reports it.
    @Published private(set) var selector: ELM327.Selector?
    /// Current gear reported by the TCM, when available. Used by the M finder screen only.
    @Published private(set) var gear: Int?

    /// Called only when `state` actually changes.
    var onStateChange: ((LampState) -> Void)?
    /// Detection messages for the dashboard log.
    var onLog: ((String) -> Void)?

    private var subscription: AnyCancellable?
    private var selectorCandidate: ELM327.Selector?
    private var selectorCount = 0

    init(obd: OBDAdapter) {
        subscription = obd.$sample.sink { [weak self] sample in self?.handle(sample) }
    }

    private func handle(_ sample: OBDSample?) {
        guard let sample else {
            selectorCandidate = nil
            selectorCount = 0
            selector = nil
            gear = nil
            return
        }

        if let gear = sample.gear { self.gear = gear }
        guard let reported = sample.selector else { return }
        if reported == selectorCandidate {
            selectorCount += 1
        } else {
            selectorCandidate = reported
            selectorCount = 1
        }
        guard selectorCount >= AppConfig.OBD.selectorConfirmReadings else { return }
        selector = reported
        if case .unknown = reported { return }
        setManual(reported.isManual, reason: "selector in \(reported.label) (from the car)")
    }

    private func setManual(_ on: Bool, reason: String) {
        let target: LampState = on ? .redBreathing : .purpleSteady
        guard state != target else { return }
        state = target
        onLog?("Manual: " + reason)
        onStateChange?(target)
    }
}
