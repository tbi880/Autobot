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
        speed.onStateChange = { [weak self] state in self?.speedStateChanged(to: state) }
    }

    // MARK: Buffer zone

    private func speedStateChanged(to state: LampState) {
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

        let now = speed.state
        if now != committed {
            committed = now
            lighting.request(now, from: .speed)   // set before the flash is withdrawn: no flicker
        }
        lighting.clear(.powerTransition)          // back to the (new or unchanged) speed scene
    }
}
