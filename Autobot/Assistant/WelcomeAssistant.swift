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
//   6. open Google Maps:
//      - a saved place was named and its address is exact -> start navigation to it
//      - a saved place with a vague address, or any other place -> search it
//      - nothing / not a destination -> just open the app
//   7. "Navigating to home." or "Find these places, you can finalize…" (nothing if no destination)
//   8. music:
//      - was playing  -> let it resume, then "The music is now continued." (if it really resumed)
//      - was not      -> run the "Lamp Drive" shortcut, which starts QQ Music "继续播放" (resume the last song)
//                        and opens Google Maps when it finishes (x-callback, also on error);
//                        announce once the music is playing
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
    private let places: SavedPlacesStore
    private let currentLocation: @MainActor () -> CLLocation?

    init(audio: AudioSessionManager, speaker: Speaker, places: SavedPlacesStore,
         currentLocation: @escaping @MainActor () -> CLLocation?) {
        self.audio = audio
        self.speaker = speaker
        self.places = places
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
        await audio.activate(.duckOthers)
        await speaker.say(AppConfig.Phrases.welcome)
        await audio.release()
        status = "Done - greeted only (app was in background)"
    }

    // MARK: Foreground conversation

    private func runConversation() async {
        let musicWasPlaying = audio.isOtherAudioPlaying
        let weatherBriefing = startWeatherBriefingIfMorning()   // fetched while we talk

        await audio.activate(.conversation)                            // pauses the music
        status = "Greeting"
        await speaker.say(AppConfig.Phrases.welcome)
        if let briefing = await weatherBriefing?.value {
            await speaker.say(briefing)
        }
        await speaker.say(AppConfig.Phrases.askDestination)

        let target = await askForDestination()

        if musicWasPlaying {
            await audio.activate(.holdOthersPaused)                    // mic off, music still paused
            await openMaps(target)
            await audio.release()                                      // music app may resume now
            await announceMusicIfResumed()
        } else {
            await audio.release()
            await startMusicAndOpenMaps(target)
        }
        status = "Done - " + target.summary
    }

    /// Listens for the reply and decides what to do in Google Maps.
    private func askForDestination() async -> MapsTarget {
        status = "Listening…"
        lastHeard = nil
        lastDestination = nil

        // English and Mandarin are recognised at the same time; most confident first,
        // and on a tie the language listed first in AppConfig.Listening.languages (English)
        let transcripts = await listener.listen()
            .enumerated()
            .sorted { ($0.element.confidence, -$0.offset) > ($1.element.confidence, -$1.offset) }
            .map(\.element)
        guard let best = transcripts.first else {
            status = "No reply"
            return .none
        }
        lastHeard = transcripts.map { "\($0.text) [\($0.localeID)]" }.joined(separator: "  /  ")

        // 1. A saved place named in any language's version ("home", "take me home", "回家")
        for transcript in transcripts {
            if let place = places.place(mentionedIn: transcript.text) {
                return target(for: place)
            }
        }
        let reply = best.text

        // 2. Anything else that sounds like a destination
        status = "Understanding (\(understandingEngine))…"
        guard let destination = await parser.destination(in: reply) else { return .none }
        if let place = places.place(mentionedIn: destination) {
            return target(for: place)
        }
        lastDestination = destination
        return .search(destination)
    }

    private func target(for place: SavedPlace) -> MapsTarget {
        lastDestination = "\(place.name) - \(place.address)"
        return place.isExactAddress ? .navigate(place) : .search(place.address)
    }

    private func openMaps(_ target: MapsTarget) async {
        guard Self.isAppInForeground else {
            status = "Skipped Google Maps (app no longer in foreground)"
            return
        }
        status = "Opening Google Maps"
        MapsLauncher.open(target)

        if let line = target.announcement {
            try? await Task.sleep(for: .seconds(1))   // let Google Maps come up first
            await speaker.say(line)
        }
    }

    /// No music was playing: the shortcut starts QQ Music, then opens Google Maps.
    /// Both announcements wait until the music is actually playing (or the timeout passes).
    private func startMusicAndOpenMaps(_ target: MapsTarget) async {
        guard Self.isAppInForeground, let mapsURL = MapsLauncher.url(for: target) else {
            status = "Skipped Google Maps (app no longer in foreground)"
            return
        }
        status = "Starting QQ Music + Google Maps"
        ShortcutsLauncher.run(named: AppConfig.Music.shortcutName, thenOpen: mapsURL)

        let musicStarted = await waitForOtherAudio(timeout: AppConfig.Music.startTimeout)
        var lines: [String] = []
        if let line = target.announcement { lines.append(line) }
        if musicStarted { lines.append(AppConfig.Phrases.musicContinued) }
        guard !lines.isEmpty else { return }

        await audio.activate(.duckOthers)
        for line in lines {
            await speaker.say(line)
        }
        await audio.release()
    }

    private func waitForOtherAudio(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if audio.isOtherAudioPlaying { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Music apps decide for themselves whether to resume, so check before saying it did.
    private func announceMusicIfResumed() async {
        try? await Task.sleep(for: .seconds(1.5))
        guard audio.isOtherAudioPlaying else { return }
        await audio.activate(.duckOthers)
        await speaker.say(AppConfig.Phrases.musicContinued)
        await audio.release()
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
