// PowerModeController.swift
// Switches Power Mode (purple steady <-> red gradient breathing) through a short
// "buffer zone" instead of jumping straight to the new lighting:
//
//   1. Speed crosses the threshold -> red burst flash for 3 s + "Power Mode Activated/Deactivated"
//   2. After 3 s the speed is checked again:
//      - still on the new side  -> switch to the new lighting (no second announcement)
//      - back on the old side    -> restore the previous lighting (no announcement)
// Speed changes during the 3 s are not acted on; only the state at the end counts.
// Crossing again later starts a new buffer zone, with its own announcement.
//
// The flash is a LightingArbiter request from `.powerTransition` (above speed, below the door
// alert), so an open door still overrides it, and withdrawing it restores the right scene.

import Combine
import Foundation

final class PowerModeController: ObservableObject {

    /// The Power Mode lighting currently in effect (purple steady or red breathing).
    @Published private(set) var committed: LampState
    /// Set during the 3-second buffer zone: the state being switched to.
    @Published private(set) var switchingTo: LampState?
    /// Test override (Power ON / OFF buttons): treated as the speed state until the real
    /// speed state changes or another test button is pressed.
    @Published private(set) var simulated: LampState?

    private let speed: SpeedMonitor
    private let lighting: LightingArbiter
    private let voice: VoiceCoordinator
    private var bufferTask: Task<Void, Never>?

    init(speed: SpeedMonitor, lighting: LightingArbiter, voice: VoiceCoordinator) {
        self.speed = speed
        self.lighting = lighting
        self.voice = voice
        self.committed = speed.state
    }

    func start() {
        lighting.request(committed, from: .speed)
        speed.onStateChange = { [weak self] state in
            self?.simulated = nil              // real driving takes over from a test
            self?.stateChanged(to: state)
        }
    }

    /// Debug: pretend the speed is on the given side of the threshold. Goes through the
    /// buffer zone (flash + announcement) exactly like real driving.
    func simulate(_ state: LampState) {
        simulated = state
        stateChanged(to: state)
    }

    /// The speed state that counts: the test override if set, otherwise the real one.
    private var currentState: LampState { simulated ?? speed.state }

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
            try? await Task.sleep(for: AppConfig.Speed.switchBufferDuration)
            self?.endBuffer()
        }
    }

    private func endBuffer() {
        bufferTask = nil
        switchingTo = nil

        let now = currentState
        if now != committed {
            committed = now
            lighting.request(now, from: .speed)   // set before the flash is withdrawn: no flicker
        }
        lighting.clear(.powerTransition)          // back to the (new or unchanged) speed scene
    }
}
