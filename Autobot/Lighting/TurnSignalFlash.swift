// TurnSignalFlash.swift
// Flashes in the current mode's colour while the turn signals or hazard lights flash: red in Power Mode,
// cyan in rain mode, purple in normal driving (rain mode's cyan never turns purple while indicating, so
// the colour always tells whether rain mode is on). When they stop, the request is withdrawn and the
// lamp shows what it should show by then:
//
//   - lever in M (Power Mode)               -> red gradient breathing again
//   - Power Mode switching                  -> its red burst flash, until the 3-second buffer ends
//   - lever in D, raining                   -> cyan gradient breathing
//   - lever in D                            -> purple steady
//
// The indicators come from the car: the indicator lamp frame 09A on HS-CAN, which OBDAdapter listens
// for every round (TurnSignals.swift). The dashboard's Left / Hazard / Right buttons stand in for them:
// a tap starts flashing, the same tap again stops it, and a change from the car takes over.
//
// The flash is a LightingArbiter request from `.turnSignal`: above Power Mode, its switch flash, and the
// A/C flash, below the door alert. Power Mode carries on underneath and the signal colour updates when
// its committed state changes, so whatever it wants at the moment the indicators stop comes back.

import Combine
import Foundation

final class TurnSignalFlash: ObservableObject {

    /// What the indicators do now: the car's, or a test's.
    @Published private(set) var state: TurnSignals.State = .off
    /// Set while a test button is in charge.
    @Published private(set) var simulated: TurnSignals.State?

    /// Test starts and stops, for the dashboard log (the car's changes are logged by OBDAdapter).
    var onLog: ((String) -> Void)?

    private let lighting: LightingArbiter
    private let powerMode: PowerModeController
    private let rain: RainMode
    private var fromCar: TurnSignals.State = .off
    private var subscription: AnyCancellable?
    private var powerModeSubscription: AnyCancellable?
    private var rainSubscription: AnyCancellable?

    init(obd: OBDAdapter, lighting: LightingArbiter, powerMode: PowerModeController, rain: RainMode) {
        self.lighting = lighting
        self.powerMode = powerMode
        self.rain = rain
        subscription = obd.$turnSignal
            .map { $0 ?? .off }                     // unknown (not heard, no live data) counts as off
            .removeDuplicates()
            .dropFirst()                            // the initial "off"
            .sink { [weak self] state in self?.carChanged(to: state) }
        powerModeSubscription = powerMode.$committed
            .dropFirst()
            .sink { [weak self] _ in self?.updateLighting() }
        rainSubscription = rain.$isOn
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isOn in self?.updateLighting(rainOn: isOn) }   // sent before it's stored
    }

    /// Debug: as if the indicators on that side (or the hazard lights) started flashing; the same
    /// button again stops them.
    func simulate(_ test: TurnSignals.State) {
        simulated = (simulated == test || test == .off) ? nil : test
        onLog?("Turn signal test: " + (simulated.map { "\($0.label) flashing" } ?? "stopped"))
        update()
    }

    // MARK: Private

    /// A change from the car takes over from a test.
    private func carChanged(to state: TurnSignals.State) {
        fromCar = state
        simulated = nil
        update()
    }

    private func update() {
        let now = simulated ?? fromCar
        guard now != state else { return }
        state = now
        updateLighting()
    }

    /// `rainOn`: rain mode's new state while it's changing (its publisher sends before storing it).
    private func updateLighting(rainOn: Bool? = nil) {
        guard state.isOn else {
            lighting.clear(.turnSignal)                 // back to Power Mode or its switch flash
            return
        }
        if powerMode.committed == .redBreathing {
            lighting.request(.redBurstFlash, from: .turnSignal)
        } else if rainOn ?? rain.isOn {
            lighting.request(.cyanBurstFlash, from: .turnSignal)
        } else {
            lighting.request(.purpleBurstFlash, from: .turnSignal)
        }
    }
}
