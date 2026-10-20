// AppModel.swift
// Creates every component and wires them together:
//
//   SpeedMonitor ──▶ PowerModeController ──scenes (speed, powerTransition)──▶ LightingArbiter ──▶ LampController
//                                        └─"Power Mode Activated/Deactivated"──▶ VoiceCoordinator
//   DoorMonitor ──▶ DoorSafetyAlert ──scene (doorAlert)──▶ LightingArbiter
//                                   └─"Door open detected"──▶ VoiceCoordinator
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
    let backup: BackupManager
    let lighting: LightingArbiter
    let doors: DoorMonitor
    let powerMode: PowerModeController
    private let voice: VoiceCoordinator
    private let doorAlert: DoorSafetyAlert

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
        let voice = VoiceCoordinator(audio: audio, speaker: speaker)
        let lighting = LightingArbiter()
        let doors = DoorMonitor()
        self.voice = voice
        self.lighting = lighting
        self.doors = doors
        self.doorAlert = DoorSafetyAlert(doors: doors, lighting: lighting, voice: voice)
        self.powerMode = PowerModeController(speed: speed, lighting: lighting, voice: voice)
        let places = SavedPlacesStore()
        self.places = places
        self.backup = BackupManager(places: places)
        self.assistant = WelcomeAssistant(audio: audio, speaker: speaker, places: places,
                                          currentLocation: { speed.lastLocation })
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        SpeechListener.requestPermissions()

        lighting.onSceneChange = { [weak self] scene in self?.lamp.setDesired(scene) }
        powerMode.start()
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
