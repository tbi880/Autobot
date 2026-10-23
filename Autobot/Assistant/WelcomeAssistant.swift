// WelcomeAssistant.swift
// The "Welcome back" flow. AppModel runs it once each time the car connects
// (lamp connected over BLE + CarPlay detected).
//
// App in the foreground (screen on, app open):
//   1. pause the music
//   2. "Welcome back, Tim."
//   3. weather briefing (6:00-11:59 only)
//      Weekday commute (CommuteCheck: Mon-Fri 7:00-9:59, near the place marked Home, a place
//      marked Work exists): no question - navigation to Work with the music handled as in step 8,
//      announcing "Navigating to work." Otherwise:
//   4. "Where is our destination today?"
//   5. listen (ends 1.5 s after speaking; gives up after 10 s of silence)
//   6. Google Maps target:
//      - a saved place was named and its address is exact -> start navigation to it
//      - a saved place with a vague address, or any other place -> search it
//      - nothing / not a destination -> just open the app
//   7. "Navigating to home." or "Find these places, you can finalize…" (nothing if no destination)
//   8. music + Google Maps:
//      - was playing  -> open Google Maps, let the music resume, then "The music is now continued."
//                        (if it really resumed)
//      - was not      -> run a shortcut (AppConfig.Music):
//                        navigation (commute, exact saved place) -> "最近播放的歌" with the
//                          navigation link: opens it, then QQ Music 最近播放
//                        search / no destination -> "Lamp Drive" with the search text:
//                          QQ Music 继续播放, then Google Maps search (Maps ends up in front)
//                        If iOS refuses to open Shortcuts, Google Maps is opened directly
//                        (no music). Announce once the music is playing.
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
    /// Diagnostics: result of the weekday-commute check, and the last shortcut run (name + input).
    @Published private(set) var lastCommuteCheck: String?
    @Published private(set) var lastShortcut: String?

    private let audio: AudioSessionManager
    private let speaker: Speaker
    private let listener = SpeechListener()
    private let parser = DestinationParser()
    private let weather = WeatherService()
    private let places: SavedPlacesStore
    private let commute: CommuteCheck
    private let currentLocation: @MainActor () -> CLLocation?

    init(audio: AudioSessionManager, speaker: Speaker, places: SavedPlacesStore,
         currentLocation: @escaping @MainActor () -> CLLocation?) {
        self.audio = audio
        self.speaker = speaker
        self.places = places
        self.commute = CommuteCheck(places: places, currentLocation: currentLocation)
        self.currentLocation = currentLocation
    }

    var understandingEngine: String { parser.engine.rawValue }

    /// Gets Apple Intelligence ready during the start screen, so the first Welcome after
    /// launch understands the reply as well as later ones.
    /// Also looks up Home's coordinates for the commute check.
    func prepare() {
        parser.prewarm()
        commute.prepare()
    }

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
        let commute = self.commute
        let commuteCheck = Task { await commute.workDestination() }   // checked while we talk

        await audio.activate(.conversation)                            // pauses the music
        status = "Greeting"
        await speaker.say(AppConfig.Phrases.welcome)
        if let briefing = await weatherBriefing?.value {
            await speaker.say(briefing)
        }

        let work = await commuteCheck.value
        lastCommuteCheck = commute.lastResult
        if let work {
            await driveToWork(work, musicWasPlaying: musicWasPlaying)
            return
        }

        await speaker.say(AppConfig.Phrases.askDestination)
        SpeechDiagnosticLog.write("WelcomeAssistant: destination prompt finished; starting speech listener")

        let target = await askForDestination()

        await openMapsAndMusic(target, announcement: target.announcement,
                               musicWasPlaying: musicWasPlaying)
        status = "Done - " + target.summary
    }

    /// Step 8: Google Maps, and the music resumed (was playing) or started (wasn't).
    /// Expects the audio session still active from the conversation (music paused).
    private func openMapsAndMusic(_ target: MapsTarget, announcement: String?,
                                  musicWasPlaying: Bool) async {
        if musicWasPlaying {
            await audio.activate(.holdOthersPaused)                    // mic off, music still paused
            await openMaps(target, announcement: announcement)
            await audio.release()                                      // music app may resume now
            await announceMusicIfResumed()
        } else {
            await audio.release()
            await startMusicAndOpenMaps(target, announcement: announcement)
        }
    }

    /// Debug: the commute hand-over right now, ignoring the day, time and distance from Home
    /// (needs a place marked Work). Call through VoiceCoordinator.
    func testCommute() async {
        guard let work = places.work else {
            status = "Commute test: no saved place is marked Work"
            return
        }
        guard Self.isAppInForeground else {
            status = "Commute test: app not in foreground"
            return
        }
        lastCommuteCheck = "Test: day, time and distance from Home not checked"
        let musicWasPlaying = audio.isOtherAudioPlaying
        await audio.activate(.conversation)                            // as in the Welcome: music paused
        await driveToWork(work, musicWasPlaying: musicWasPlaying)
    }

    /// Weekday-morning commute from Home: no question, straight to Work (navigation link),
    /// with the music handled as for any other destination.
    private func driveToWork(_ work: SavedPlace, musicWasPlaying: Bool) async {
        lastHeard = nil
        lastDestination = "\(work.name) - \(work.address) (commute)"
        await openMapsAndMusic(.navigate(work), announcement: AppConfig.Phrases.navigatingToWork,
                               musicWasPlaying: musicWasPlaying)
        status = "Done - commute: navigating to work"
    }

    /// Listens for the reply and decides what to do in Google Maps.
    private func askForDestination() async -> MapsTarget {
        status = "Listening…"
        lastHeard = nil
        lastDestination = nil

        // English and Mandarin are recognised at the same time; most confident first,
        // and on a tie the language listed first in AppConfig.Listening.languages (English)
        let transcripts = await listener.listen(contextualStrings: places.places.map(\.name))
            .enumerated()
            .sorted { ($0.element.confidence, -$0.offset) > ($1.element.confidence, -$1.offset) }
            .map(\.element)
        SpeechDiagnosticLog.write("WelcomeAssistant: listener returned \(transcripts.count) transcript(s)")
        guard let best = transcripts.first else {
            SpeechDiagnosticLog.write("WelcomeAssistant: no reply because listener returned no transcript")
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
        if let place = places.place(similarTo: destination) {
            return target(for: place)
        }
        lastDestination = destination
        return .search(destination)
    }

    private func target(for place: SavedPlace) -> MapsTarget {
        lastDestination = "\(place.name) - \(place.address)"
        return place.isExactAddress ? .navigate(place) : .search(place.address)
    }

    private func openMaps(_ target: MapsTarget, announcement: String?) async {
        guard Self.isAppInForeground else {
            status = "Skipped Google Maps (app no longer in foreground)"
            return
        }
        status = "Opening Google Maps"
        MapsLauncher.open(target)

        if let line = announcement {
            try? await Task.sleep(for: .seconds(1))   // let Google Maps come up first
            await speaker.say(line)
        }
    }

    /// No music was playing: the QQ Music shortcut runs, then opens Google Maps itself.
    /// `announcement` (where we're going) and "The music is now continued." wait until the
    /// music is actually playing (or the timeout passes).
    private func startMusicAndOpenMaps(_ target: MapsTarget, announcement: String?) async {
        guard Self.isAppInForeground, let mapsURL = MapsLauncher.url(for: target) else {
            status = "Skipped Google Maps (app no longer in foreground)"
            return
        }
        status = "Starting QQ Music + Google Maps"
        let (name, input) = Self.shortcut(for: target, mapsURL: mapsURL)
        let outcome = await playMusicThenOpenMaps(shortcut: name, input: input, mapsURL: mapsURL)
        lastShortcut = "\(name) <- " + (input.map { "\"\($0)\"" } ?? "no input") + ": \(outcome)"
        SpeechDiagnosticLog.write("WelcomeAssistant: shortcut " + (lastShortcut ?? ""))

        // Let the shortcut bring Google Maps up first (music that was only paused by us
        // resumes almost at once, so don't announce before the hand-over has started)
        try? await Task.sleep(for: .seconds(1))
        let musicStarted = await waitForOtherAudio(timeout: AppConfig.Music.startTimeout)
        var lines: [String] = []
        if let line = announcement { lines.append(line) }
        if musicStarted { lines.append(AppConfig.Phrases.musicContinued) }
        guard !lines.isEmpty else { return }

        await audio.activate(.duckOthers)
        for line in lines {
            await speaker.say(line)
        }
        await audio.release()
    }

    /// Which shortcut, and its input:
    /// - navigation (commute, saved place with an exact address): the navigation link, so the
    ///   shortcut opens it first (the route starts by itself) and then starts QQ Music
    /// - search: the text, for Lamp Drive's Google Maps Search action (Maps ends up in front)
    /// - no destination: Lamp Drive without input (it just opens Google Maps)
    private static func shortcut(for target: MapsTarget, mapsURL: URL) -> (name: String, input: String?) {
        switch target {
        case .navigate: return (AppConfig.Music.navigateShortcutName, mapsURL.absoluteString)
        case .search(let text): return (AppConfig.Music.searchShortcutName, text)
        case .none: return (AppConfig.Music.searchShortcutName, nil)
        }
    }

    /// Runs the shortcut, which starts QQ Music and opens Google Maps itself. If iOS refuses to
    /// open Shortcuts, Google Maps is opened directly instead (no music), so Maps always opens.
    /// Returns what happened, for the dashboard and the diagnostic log.
    private func playMusicThenOpenMaps(shortcut name: String, input: String?, mapsURL: URL) async -> String {
        if let url = ShortcutsLauncher.url(named: name, input: input),
           await ShortcutsLauncher.open(url) {
            return "opened"
        }
        let canOpen = ShortcutsLauncher.canOpenShortcuts
        SpeechDiagnosticLog.write("WelcomeAssistant: iOS refused to open Shortcuts "
                                  + "(app state \(UIApplication.shared.applicationState.rawValue), "
                                  + "canOpenURL(shortcuts://) = \(canOpen))")
        guard Self.isAppInForeground else { return "Shortcuts refused; app left the foreground" }
        let mapsOpened = await UIApplication.shared.open(mapsURL, options: [:])
        return "Shortcuts REFUSED (canOpenURL(shortcuts://) = \(canOpen)); no music; "
            + "Google Maps opened directly: " + (mapsOpened ? "yes" : "NO")
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
