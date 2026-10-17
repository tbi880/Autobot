// WelcomeAssistant.swift
// The "Welcome back" flow. AppModel runs it once each time the car connects
// (lamp connected over BLE + CarPlay detected).
//
// App in the foreground (screen on, app open):
//   1. pause the music
//   2. "Welcome back, Tim."
//   3. weather briefing (6:00-11:59 only)
//   4. "Where is our destination today?"
//   5. listen (ends 1.5 s after speaking; gives up after 10 s of silence)
//   6. open Google Maps, searching the destination if one was heard
//   7. "Find these places, you can finalize the destination manually." (only with a destination)
//   8. let the music resume, then "The music is now continued." (only if it really resumed)
//
// App in the background or phone locked:
//   only "Welcome back, Tim." (music is lowered, not paused)

import Combine
import CoreLocation
import UIKit

final class WelcomeAssistant: ObservableObject {

    @Published private(set) var status = "Waiting for car"
    @Published private(set) var lastHeard: String?
    @Published private(set) var lastDestination: String?

    private let audio: AudioSessionManager
    private let speaker: Speaker
    private let listener = SpeechListener()
    private let parser = DestinationParser()
    private let weather = WeatherService()
    private let currentLocation: @MainActor () -> CLLocation?

    init(audio: AudioSessionManager, speaker: Speaker, currentLocation: @escaping @MainActor () -> CLLocation?) {
        self.audio = audio
        self.speaker = speaker
        self.currentLocation = currentLocation
    }

    var understandingEngine: String { parser.engine.rawValue }

    /// Entry point. Call through VoiceCoordinator so nothing else speaks at the same time.
    func run() async {
        if Self.isAppInForeground {
            await runConversation()
        } else {
            await greetOnly()
        }
    }

    // MARK: Background / locked

    private func greetOnly() async {
        status = "Greeting (app in background)"
        audio.activate(.duckOthers)
        await speaker.say(AppConfig.Phrases.welcome)
        audio.release()
        status = "Done - greeted only (app was in background)"
    }

    // MARK: Foreground conversation

    private func runConversation() async {
        let musicWasPlaying = audio.isOtherAudioPlaying
        let weatherBriefing = startWeatherBriefingIfMorning()   // fetched while we talk

        audio.activate(.conversation)                            // pauses the music
        status = "Greeting"
        await speaker.say(AppConfig.Phrases.welcome)
        if let briefing = await weatherBriefing?.value {
            await speaker.say(briefing)
        }
        await speaker.say(AppConfig.Phrases.askDestination)

        let destination = await askForDestination()

        audio.activate(.holdOthersPaused)                        // mic off, music still paused
        await openMaps(searching: destination)
        audio.release()                                          // music app may resume now

        if musicWasPlaying {
            await announceMusicIfResumed()
        }
        status = "Done - " + (destination.map { "searched \"\($0)\"" } ?? "opened Google Maps")
    }

    /// Listens for the reply and extracts a destination. nil = no reply, or not a destination.
    private func askForDestination() async -> String? {
        status = "Listening…"
        lastHeard = nil
        lastDestination = nil

        guard let reply = await listener.listen() else {
            status = "No reply"
            return nil
        }
        lastHeard = reply

        status = "Understanding (\(understandingEngine))…"
        let destination = await parser.destination(in: reply)
        lastDestination = destination
        return destination
    }

    private func openMaps(searching destination: String?) async {
        guard Self.isAppInForeground else {
            status = "Skipped Google Maps (app no longer in foreground)"
            return
        }
        status = "Opening Google Maps"
        MapsLauncher.open(searching: destination)

        if destination != nil {
            try? await Task.sleep(for: .seconds(1))   // let Google Maps come up first
            await speaker.say(AppConfig.Phrases.foundPlaces)
        }
    }

    /// Music apps decide for themselves whether to resume, so check before saying it did.
    private func announceMusicIfResumed() async {
        try? await Task.sleep(for: .seconds(1.5))
        guard audio.isOtherAudioPlaying else { return }
        audio.activate(.duckOthers)
        await speaker.say(AppConfig.Phrases.musicContinued)
        audio.release()
    }

    // MARK: Helpers

    private func startWeatherBriefingIfMorning() -> Task<String?, Never>? {
        guard WeatherService.isMorning, let location = currentLocation() else { return nil }
        let weather = self.weather
        return Task { await weather.briefing(at: location) }
    }

    private static var isAppInForeground: Bool {
        UIApplication.shared.applicationState == .active
    }
}
