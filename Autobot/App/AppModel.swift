// AppModel.swift
// Creates every component and wires them together:
//
//   MFinder (finds the M flag once) ──learned M flag──▶ OBDAdapter (TCM: P/R/N, gear, M/D)
//   OBDAdapter ──live data──▶ ManualShiftDetector ──▶ PowerModeController ──scenes (powerMode, powerTransition)──▶ LightingArbiter ──▶ LampController
//                                                                         └─"Power Mode Activated/Deactivated"──▶ VoiceCoordinator
//     (AppConfig.PowerMode.trigger: ManualShiftDetector, EngineMonitor (RPM only) or SpeedMonitor (GPS))
//   SpeedMonitor (GPS) ──▶ speed on the dashboard, location for the weather briefing / commute check
//   OBDAdapter (BCM door status 726 22C150; DoorFinder fills in doors it learned) ──doorStates──▶ DoorMonitor
//   DoorMonitor ──▶ DoorSafetyAlert ──scene (doorAlert)──▶ LightingArbiter
//                                   └─"Door open detected"──▶ VoiceCoordinator
//   A/C set temperature (dashboard test buttons for now: the climate control unit is on MS-CAN, out
//   of the KW905's reach) ──▶ ClimateTempFlash ──scene (climateTemp: blue / red flash)──▶ LightingArbiter
//   OBDAdapter (TCM gear 7E1 221E12: 3C = lever in R) ──sample──▶ ReverseLight
//     ──scene (reverse: yellow breathing, Power Mode's level)──▶ LightingArbiter
//   OBDAdapter (indicator lamp frame 09A, listened for on HS-CAN) ──turnSignal──▶ TurnSignalFlash
//     ──scene (turnSignal: yellow flash, above Power Mode)──▶ LightingArbiter
//   LampController.isReady ┐
//   CarPlayMonitor.isConnected ┼──▶ WelcomeAssistant (once per drive, via VoiceCoordinator)
//   BootSequence finished ─────┘
//
// Nothing starts until the ENGINE START button is pressed (ignite): then the lamp and OBD2
// Bluetooth searches and CarPlay detection start together, and the start screen (BootSequence)
// follows the lamp and CarPlay. The first Welcome waits until the start screen has finished.

import AVFoundation
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
    let obd: OBDAdapter
    let engine: EngineMonitor
    let manual: ManualShiftDetector
    let mFinder: MFinder
    let doorFinder: DoorFinder
    let boot: BootSequence
    let climate: ClimateTempFlash
    let turnSignals: TurnSignalFlash
    let reverse: ReverseLight
    private let voice: VoiceCoordinator
    private let doorAlert: DoorSafetyAlert

    private var hasStarted = false
    private var greetedThisDrive = false
    private var bootFinished = false
    private var subscriptions = Set<AnyCancellable>()

    init() {
        let audio = AudioSessionManager()
        let speaker = Speaker()
        let speed = SpeedMonitor()

        let lamp = LampController()
        speaker.onLog = { [weak lamp] message in lamp?.addLog(message) }

        self.lamp = lamp
        self.speed = speed
        let carPlay = CarPlayMonitor()
        self.carPlay = carPlay
        let voice = VoiceCoordinator(audio: audio, speaker: speaker)
        let lighting = LightingArbiter()
        let doors = DoorMonitor()
        self.voice = voice
        self.lighting = lighting
        self.doors = doors
        self.doorAlert = DoorSafetyAlert(doors: doors, lighting: lighting, voice: voice)
        let climate = ClimateTempFlash(lighting: lighting)
        climate.onLog = { [weak lamp] message in lamp?.addLog(message) }
        self.climate = climate
        let obd = OBDAdapter()
        obd.onLog = { [weak lamp] message in lamp?.addLog(message) }
        let engine = EngineMonitor(obd: obd)
        let manual = ManualShiftDetector(obd: obd)
        manual.onLog = { [weak lamp] message in lamp?.addLog(message) }
        self.obd = obd
        self.engine = engine
        let turnSignals = TurnSignalFlash(obd: obd, lighting: lighting)
        turnSignals.onLog = { [weak lamp] message in lamp?.addLog(message) }
        self.turnSignals = turnSignals
        let reverse = ReverseLight(obd: obd, lighting: lighting)
        reverse.onLog = { [weak lamp] message in lamp?.addLog(message) }
        self.reverse = reverse
        self.manual = manual
        let mFinder = MFinder(obd: obd)
        mFinder.onLog = { [weak lamp] message in lamp?.addLog(message) }
        self.mFinder = mFinder
        let doorFinder = DoorFinder(obd: obd)
        doorFinder.onLog = { [weak lamp] message in lamp?.addLog(message) }
        self.doorFinder = doorFinder
        let trigger: any PowerModeTrigger
        switch AppConfig.PowerMode.trigger {
        case .manualShift: trigger = manual
        case .engineRPM: trigger = engine
        case .speed: trigger = speed
        }
        self.powerMode = PowerModeController(trigger: trigger, lighting: lighting, voice: voice)
        let places = SavedPlacesStore()
        self.places = places
        self.backup = BackupManager(places: places)
        self.assistant = WelcomeAssistant(audio: audio, speaker: speaker, places: places,
                                          currentLocation: { speed.lastLocation })
        self.boot = BootSequence(lamp: lamp, carPlay: carPlay, engineSound: EngineSoundPlayer(audio: audio))
        boot.onFinished = { [weak self] in self?.bootDidFinish() }
    }

    /// ENGINE START pressed: start-up effects, and everything start() connects.
    func ignite() {
        boot.ignite()
        start()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        SpeechListener.requestPermissions()
        lamp.start()
        Self.warmUpSpeech()
        assistant.prepare()

        lighting.onSceneChange = { [weak self] scene in self?.lamp.setDesired(scene) }
        powerMode.start()
        speed.start()
        obd.start()
        carPlay.start()

        obd.$doorStates
            .sink { [weak self] states in self?.doorStatesChanged(states) }
            .store(in: &subscriptions)

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

    /// Debug: the weekday-commute hand-over (navigation to Work + music) right now.
    func testCommute() {
        let assistant = self.assistant
        voice.runConversation { await assistant.testCommute() }
    }

    /// Debug: behave as if the Power Mode trigger switched to `state` (buffer zone, announcement, lighting).
    func testPowerMode(_ state: LampState) {
        powerMode.simulate(state)
    }

    /// Debug: as if the A/C temperature dial was turned one click colder or warmer.
    func testClimate(_ direction: ClimateTempFlash.Direction) {
        climate.simulateTurn(direction)
    }

    /// Debug: as if the indicators on that side (or the hazard lights) started flashing; the same
    /// button again stops them.
    func testTurnSignal(_ state: TurnSignals.State) {
        turnSignals.simulate(state)
    }

    /// Debug: as if the lever went into R; the same button again hands back to the car's lever.
    func testReverse() {
        reverse.simulate()
    }

    // MARK: Wiring

    /// Greets once per drive, when both the lamp and CarPlay are connected (in either order),
    /// after the start screen has finished.
    private func connectionChanged(lampReady: Bool, carPlayConnected: Bool) {
        guard carPlayConnected else {
            greetedThisDrive = false   // car disconnected: next connection is a new drive
            return
        }
        guard lampReady, bootFinished, !greetedThisDrive else { return }
        greetedThisDrive = true
        runWelcome()
    }

    /// Real door states from the car (the BCM's door status, or doors DoorFinder learned):
    /// DoorMonitor follows them, so the door alert works on real data. When they become unknown
    /// (live data stopped) everything counts as closed again. Without any door signal the test
    /// buttons stay in charge.
    private func doorStatesChanged(_ states: [DoorMonitor.Opening: Bool]) {
        guard !states.isEmpty else {
            guard !obd.doorSignals.isEmpty else { return }
            for opening in DoorMonitor.Opening.allCases { doors.setOpen(opening, false) }
            return
        }
        for (opening, isOpen) in states { doors.setOpen(opening, isOpen) }
    }

    /// Start screen done (engine sound already stopped). The Welcome may start once the
    /// transition into the dashboard has played, so it doesn't make the animation stutter.
    private func bootDidFinish() {
        let delay = AppConfig.Boot.dashboardTransition + AppConfig.Boot.welcomeDelayAfterTransition
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.bootFinished = true
            self.connectionChanged(lampReady: self.lamp.isReady, carPlayConnected: self.carPlay.isConnected)
        }
    }

    /// The first look-up of the installed voices can take a while; doing it in the background
    /// during the start screen means the Welcome doesn't pay for it on the main thread.
    private static func warmUpSpeech() {
        Task.detached(priority: .utility) {
            _ = AVSpeechSynthesisVoice.speechVoices().count
        }
    }

    private func runWelcome() {
        let assistant = self.assistant
        voice.runConversation { await assistant.run() }
    }
}
