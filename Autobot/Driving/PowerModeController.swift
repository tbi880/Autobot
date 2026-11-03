// PowerModeController.swift
// When the trigger changes, show the red burst flash and announcement for the buffer duration,
// then recheck the trigger and apply its current Power Mode. This keeps the visible transition while
// allowing a brief selector fluctuation to settle before committing the breathing scene.
//
// The trigger is the real manual selector (ManualShiftDetector) or GPS speed. Power Mode asks for
// red breathing (`.powerMode`) while on; when off it withdraws its request so rain mode's cyan
// breathing or the normal purple steady scene underneath can show.

import Combine
import Foundation

/// The active Power Mode side: `.redBreathing` or `.purpleSteady`, already debounced.
@MainActor
protocol PowerModeTrigger: AnyObject {
    var state: LampState { get }
    /// Called only when `state` actually changes.
    var onStateChange: ((LampState) -> Void)? { get set }
}

final class PowerModeController: ObservableObject {

    /// The Power Mode lighting currently in effect (purple steady or red breathing).
    @Published private(set) var committed: LampState
    /// Set during the 3-second buffer zone: the state requested by the trigger.
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

    /// Debug: run through the same buffer, announcement and lighting change as the real trigger.
    func simulate(_ state: LampState) {
        simulated = state
        stateChanged(to: state)
    }

    /// The trigger state that counts: test override if present, otherwise the real trigger state.
    private var currentState: LampState { simulated ?? trigger.state }

    private func stateChanged(to state: LampState) {
        guard bufferTask == nil, state != committed else { return }
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
            applyPowerMode(now)                   // apply before withdrawing the flash
        }
        lighting.clear(.powerTransition)
    }

    /// Power Mode on: red breathing. Off: rain mode or the normal purple steady scene shows through.
    private func applyPowerMode(_ state: LampState) {
        if state == .redBreathing {
            lighting.request(.redBreathing, from: .powerMode)
        } else {
            lighting.clear(.powerMode)
        }
    }
}
