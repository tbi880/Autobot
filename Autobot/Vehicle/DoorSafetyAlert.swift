// DoorSafetyAlert.swift
// When any door or the boot opens: red burst flash (top lighting priority, overrides the
// speed scene) and the assistant voice says "Door open detected".
// When everything is closed again: the alert is withdrawn and the lamp goes back to
// whatever it should show now. No announcement on closing.

import Combine
import Foundation

final class DoorSafetyAlert {

    private let lighting: LightingArbiter
    private let voice: VoiceCoordinator
    private var subscription: AnyCancellable?

    init(doors: DoorMonitor, lighting: LightingArbiter, voice: VoiceCoordinator) {
        self.lighting = lighting
        self.voice = voice
        subscription = doors.$open
            .map { !$0.isEmpty }
            .removeDuplicates()
            .dropFirst()                       // ignore the initial "all closed"
            .sink { [weak self] anyOpen in self?.anyOpenChanged(anyOpen) }
    }

    private func anyOpenChanged(_ anyOpen: Bool) {
        if anyOpen {
            lighting.request(.redBurstFlash, from: .doorAlert)
            voice.announce(AppConfig.Phrases.doorOpen, urgent: true)
        } else {
            lighting.clear(.doorAlert)
        }
    }
}
