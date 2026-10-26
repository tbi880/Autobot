// PowerModeController.swift
// Switches Power Mode (purple steady <-> red gradient breathing) through a short
// "buffer zone" instead of jumping straight to the new lighting:
//
//   1. The trigger crosses the threshold -> red burst flash for 3 s + "Power Mode Activated/Deactivated"
//   2. After 3 s the trigger is checked again:
//      - still on the new side  -> switch to the new lighting (no second announcement)
//      - back on the old side    -> restore the previous lighting (no announcement)
// Changes during the 3 s are not acted on; only the state at the end counts.
// Crossing again later starts a new buffer zone, with its own announcement.
//
// The trigger (AppConfig.PowerMode.trigger) is manual shifting worked out from the OBD2 live data
// (ManualShiftDetector), the engine RPM alone (EngineMonitor, 2500 r/min) or the GPS speed
// (SpeedMonitor, 90 km/h).
//
// The flash is a LightingArbiter request from `.powerTransition` (above Power Mode, below the
// door alert), so an open door still overrides it, and withdrawing it restores the right scene.
// Power Mode itself only asks for red breathing (`.powerMode`) while it's on; when it's off it
// withdraws, so what's underneath shows: rain mode's cyan breathing (`.rain`) or the normal purple
// steady (`.base`).

import Combine
import Foundation

/// Decides which side of the Power Mode threshold the car is on: `.redBreathing` (Power Mode)
/// or `.purpleSteady`, already debounced. Provided by ManualShiftDetector, EngineMonitor (RPM) or
/// SpeedMonitor (GPS).
@MainActor
protocol PowerModeTrigger: AnyObject {
    var state: LampState { get }
    /// Called only when `state` actually changes.
    var onStateChange: ((LampState) -> Void)? { get set }
}

final class PowerModeController: ObservableObject {

    /// The Power Mode lighting currently in effect (purple steady or red breathing).
    @Published private(set) var committed: LampState
    /// Set during the 3-second buffer zone: the state being switched to.
    @Published private(set) var switchingTo: LampState?
    /// Test override (Power ON / OFF buttons): treated as the trigger state until the real
    /// trigger state changes or another test button is pressed.
    @Published private(set) var simulated: LampState?

    private let trigger: any PowerModeTrigger
    private let lighting: LightingArbiter
    private let voice: VoiceCoordinator
    private var bufferTask: Task<Void, Never>?

    init(trigger: any PowerModeTrigger, lighting: LightingArbiter, voice: VoiceCoordinator) {
        self.trigger = trigger
        self.lighting = lighting
        self.voice = voice
        self.committed = trigger.state
    }

    func start() {
        applyPowerMode(committed)
        trigger.onStateChange = { [weak self] state in
            self?.simulated = nil              // real driving takes over from a test
            self?.stateChanged(to: state)
        }
    }

    /// Debug: pretend the trigger (manual shifting, RPM or speed) is on the given side. Goes
    /// through the buffer zone (flash + announcement) exactly like real driving.
    func simulate(_ state: LampState) {
        simulated = state
        stateChanged(to: state)
    }

    /// The trigger state that counts: the test override if set, otherwise the real one.
    private var currentState: LampState { simulated ?? trigger.state }

    // MARK: Buffer zone

    private func stateChanged(to state: LampState) {
        guard bufferTask == nil, state != committed else { return }   // decided at the end of a running buffer
        beginBuffer(switchingTo: state)
    }

    private func beginBuffer(switchingTo target: LampState) {
        switchingTo = target
        lighting.request(.redBurstFlash, from: .powerTransition)
        voice.announcePowerChange(to: target)

        bufferTask = Task { [weak self] in
            try? await Task.sleep(for: AppConfig.PowerMode.switchBufferDuration)
            self?.endBuffer()
        }
    }

    private func endBuffer() {
        bufferTask = nil
        switchingTo = nil

        let now = currentState
        if now != committed {
            committed = now
            applyPowerMode(now)                       // set before the flash is withdrawn: no flicker
        }
        lighting.clear(.powerTransition)              // back to the (new or unchanged) Power Mode scene
    }

    /// Power Mode on: red breathing from `.powerMode`. Off: no request, so the scene underneath shows
    /// (rain mode's cyan breathing, or the normal purple steady).
    private func applyPowerMode(_ state: LampState) {
        if state == .redBreathing {
            lighting.request(.redBreathing, from: .powerMode)
        } else {
            lighting.clear(.powerMode)
        }
    }
}
