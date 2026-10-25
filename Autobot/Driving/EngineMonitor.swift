// EngineMonitor.swift
// Power Mode from the engine RPM alone (AppConfig.PowerMode.trigger = .engineRPM):
//   rpm >= 2500 r/min for 0.5 s  -> red gradient breathing (Power Mode)
//   rpm <  2500 r/min for 5 s    -> purple steady
// Switching off waits longer, so the dip below the threshold after each upshift doesn't end
// Power Mode in the middle of an acceleration. Values: AppConfig.Engine.
// The default trigger is ManualShiftDetector, which also looks at speed, gear and pedal.

import Combine
import Foundation

final class EngineMonitor: ObservableObject, PowerModeTrigger {

    @Published private(set) var state: LampState = .purpleSteady

    /// Called only when the state actually changes (after the confirmation time).
    var onStateChange: ((LampState) -> Void)?

    private var candidate: LampState?
    private var candidateSince: Date?
    private var subscription: AnyCancellable?

    init(obd: OBDAdapter) {
        subscription = obd.$sample.sink { [weak self] sample in self?.reading(sample?.rpm) }
    }

    /// One RPM reading (a few per second), or nil when readings stop.
    private func reading(_ rpm: Double?) {
        guard let rpm else {
            candidate = nil              // no readings: keep the state, forget a pending switch
            return
        }
        let target: LampState = rpm >= AppConfig.Engine.powerModeThresholdRpm ? .redBreathing : .purpleSteady
        guard target != state else {
            candidate = nil
            return
        }
        let now = Date()
        if candidate != target {
            candidate = target
            candidateSince = now
        }
        let needed = target == .redBreathing ? AppConfig.Engine.confirmOn : AppConfig.Engine.confirmOff
        guard let since = candidateSince, now.timeIntervalSince(since) >= needed else { return }
        state = target
        candidate = nil
        onStateChange?(target)
    }
}
