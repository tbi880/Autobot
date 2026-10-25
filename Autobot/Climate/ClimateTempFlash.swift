// ClimateTempFlash.swift
// Flashes the lamp when the A/C temperature is turned: colder -> blue burst flash, warmer -> red
// burst flash, lasting 3 seconds after the last click of the dial (AppConfig.Climate.flashDuration):
//
//   - turned further the same way while it flashes -> the 3 seconds start again
//   - turned the other way                          -> the other colour at once: the later turn wins
//                                                      (2 °C down, then up: red on the first click
//                                                      up), with its own 3 seconds
//   - 3 seconds without a click                     -> back to what was shown before (Power Mode…)
//
// All it needs is the set temperature, one reading after another (setPointChanged(to:)). The first
// reading is the reference and doesn't flash, nor does the first one after the value was unknown.
// On the 2015 CX-5 the set temperature is held by the climate control unit on the MS-CAN bus (OBD
// pins 3/11), which the KW905 can't reach (OBDAdapter.reportsClimateUnit, README "A/C set temperature"),
// so for now the dashboard's A/C − / A/C + test buttons drive it.
//
// The flash is a LightingArbiter request from `.climateTemp` (above Power Mode and its switch flash,
// below the door alert); withdrawing it brings back the scene underneath. More clicks the same way
// send nothing to the lamp: the scene stays the same, only the time starts again.

import Combine
import Foundation

final class ClimateTempFlash: ObservableObject {

    enum Direction: Equatable {
        case colder, warmer

        /// Blue for colder, red for warmer.
        var scene: LampState { self == .colder ? .blueBurstFlash : .redBurstFlash }
    }

    /// The latest set temperature (°C); nil while unknown.
    @Published private(set) var setPoint: Double?
    /// The flash showing now; nil when none.
    @Published private(set) var flashing: Direction?
    /// True while the set temperature comes from the test buttons, not from the car.
    @Published private(set) var simulated = false

    /// Flash starts and colour changes, for the dashboard log.
    var onLog: ((String) -> Void)?

    private let lighting: LightingArbiter
    private var flashTask: Task<Void, Never>?

    init(lighting: LightingArbiter) {
        self.lighting = lighting
    }

    /// A new reading of the set temperature (°C) from the car; nil = unknown now (the source went
    /// away). A single missed reading should simply not be reported, so no click gets lost.
    func setPointChanged(to value: Double?) {
        if simulated {                       // real readings take over from a test: start from them
            simulated = false
            setPoint = nil
        }
        update(to: value)
    }

    /// Debug: as if the dial was turned one click (AppConfig.Climate.testStep) colder or warmer.
    func simulateTurn(_ direction: Direction) {
        let current = setPoint ?? AppConfig.Climate.testStartTemperature
        setPoint = current                   // the reference for the first test click
        simulated = true
        let step = AppConfig.Climate.testStep
        update(to: current + (direction == .colder ? -step : step))
    }

    // MARK: Flash

    private func update(to value: Double?) {
        let previous = setPoint
        setPoint = value
        guard let value, let previous, value != previous else { return }   // reference, unknown or same
        flash(value < previous ? .colder : .warmer, from: previous, to: value)
    }

    /// Shows the direction's colour and starts its 3 seconds again. Same direction as now: the
    /// arbiter already shows it, so only the time restarts. The other direction: it replaces the
    /// current colour straight away.
    private func flash(_ direction: Direction, from previous: Double, to value: Double) {
        if flashing != direction {
            onLog?("A/C " + String(format: "%.1f → %.1f °C", previous, value) + ": \(direction.scene.label)")
        }
        flashing = direction
        lighting.request(direction.scene, from: .climateTemp)
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: AppConfig.Climate.flashDuration)
            guard !Task.isCancelled else { return }        // another click came first
            self?.endFlash()
        }
    }

    private func endFlash() {
        flashTask = nil
        flashing = nil
        lighting.clear(.climateTemp)
    }
}
