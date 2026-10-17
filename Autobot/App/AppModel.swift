// AppModel.swift
// Creates every component and wires them together:
//
//   SpeedMonitor ──state──▶ LampController       (purple steady / red breathing)
//                └─state──▶ VoiceCoordinator     ("Power Mode Activated/Deactivated")
//   LampController.isReady ┐
//   CarPlayMonitor.isConnected ┴──▶ WelcomeAssistant (once per drive, via VoiceCoordinator)

import Combine
import SwiftUI

final class AppModel: ObservableObject {

    let lamp: LampController
    let speed: SpeedMonitor
    let carPlay: CarPlayMonitor
    let assistant: WelcomeAssistant
    let places: SavedPlacesStore
    private let voice: VoiceCoordinator

    private var hasStarted = false
    private var greetedThisDrive = false
    private var subscriptions = Set<AnyCancellable>()

    init() {
        let audio = AudioSessionManager()
        let speaker = Speaker()
        let speed = SpeedMonitor()

        let lamp = LampController()
        speaker.onLog = { [weak lamp] message in lamp?.addLog(message) }

        self.lamp = lamp
        self.speed = speed
        self.carPlay = CarPlayMonitor()
        self.voice = VoiceCoordinator(audio: audio, speaker: speaker)
        let places = SavedPlacesStore()
        self.places = places
        self.assistant = WelcomeAssistant(audio: audio, speaker: speaker, places: places,
                                          currentLocation: { speed.lastLocation })
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        SpeechListener.requestPermissions()

        speed.onStateChange = { [weak self] state in self?.speedStateChanged(to: state) }
        lamp.setDesired(speed.state)
        speed.start()
        carPlay.start()

        Publishers.CombineLatest(lamp.$isReady, carPlay.$isConnected)
            .sink { [weak self] lampReady, carPlayConnected in
                self?.connectionChanged(lampReady: lampReady, carPlayConnected: carPlayConnected)
            }
            .store(in: &subscriptions)
    }

    /// Debug: run the welcome flow without a car.
    func testWelcome() {
        runWelcome()
    }

    /// Debug: plays "Power Mode Activated" (red) or "Power Mode Deactivated" (purple).
    func testPowerVoice(_ state: LampState) {
        voice.testPowerVoice(for: state)
    }

    // MARK: Wiring

    private func speedStateChanged(to state: LampState) {
        lamp.setDesired(state)
        voice.announcePowerChange(to: state)
    }

    /// Greets once per drive, when both the lamp and CarPlay are connected (in either order).
    private func connectionChanged(lampReady: Bool, carPlayConnected: Bool) {
        guard carPlayConnected else {
            greetedThisDrive = false   // car disconnected: next connection is a new drive
            return
        }
        guard lampReady, !greetedThisDrive else { return }
        greetedThisDrive = true
        runWelcome()
    }

    private func runWelcome() {
        let assistant = self.assistant
        voice.runConversation { await assistant.run() }
    }
}
