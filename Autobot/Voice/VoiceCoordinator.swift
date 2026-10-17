// VoiceCoordinator.swift
// The single place everything goes through to speak, so only one voice plays at a time.
//
// Queue order:
//   1. Urgent announcements (e.g. "Door open detected") go to the front of the queue.
//   2. The welcome conversation comes next.
//   3. Normal announcements and Power Mode announcements wait their turn. If the speed
//      state flips several times meanwhile, only the latest Power Mode state is announced,
//      and nothing is said if it ends up back where it was last announced.
// Something already playing is never cut off.
//
// Every announcement is spoken navigation-style: other apps' audio is ducked, not paused.

import Foundation

final class VoiceCoordinator {

    private nonisolated enum Job {
        case conversation(@MainActor () async -> Void)
        case announcement(String, Speaker.Style, urgent: Bool)
        case powerAnnouncement

        var isPowerAnnouncement: Bool {
            if case .powerAnnouncement = self { return true }
            return false
        }

        var isUrgent: Bool {
            if case .announcement(_, _, urgent: true) = self { return true }
            return false
        }
    }

    private let audio: AudioSessionManager
    private let speaker: Speaker

    private var jobs: [Job] = []
    private var isBusy = false
    private var latestPowerState: LampState = .purpleSteady
    private var lastAnnouncedPowerState: LampState = .purpleSteady

    init(audio: AudioSessionManager, speaker: Speaker) {
        self.audio = audio
        self.speaker = speaker
    }

    // MARK: Public API

    /// Speaks a sentence (ducking other audio). `urgent` puts it at the front of the queue.
    func announce(_ text: String, style: Speaker.Style = .assistant, urgent: Bool = false) {
        let job = Job.announcement(text, style, urgent: urgent)
        if urgent {
            // After other urgent ones (keeps their order), before everything else
            jobs.insert(job, at: jobs.firstIndex { !$0.isUrgent } ?? jobs.count)
        } else {
            jobs.append(job)
        }
        runNextJob()
    }

    /// Queues a conversation ahead of normal and Power Mode announcements
    /// (but behind urgent ones already waiting).
    func runConversation(_ work: @escaping @MainActor () async -> Void) {
        let firstNormal = jobs.firstIndex { !$0.isUrgent && !Self.isConversation($0) } ?? jobs.count
        jobs.insert(.conversation(work), at: firstNormal)
        runNextJob()
    }

    /// Queues "Power Mode Activated/Deactivated" for the given speed state.
    func announcePowerChange(to state: LampState) {
        latestPowerState = state
        if !jobs.contains(where: \.isPowerAnnouncement) {
            jobs.append(.powerAnnouncement)
        }
        runNextJob()
    }

    /// Debug: plays the Power Mode phrase for `state`, without changing what has been announced.
    func testPowerVoice(for state: LampState) {
        guard let phrase = Self.powerPhrase(for: state) else { return }
        announce(phrase.text, style: phrase.style)
    }

    // MARK: Queue

    private static func isConversation(_ job: Job) -> Bool {
        if case .conversation = job { return true }
        return false
    }

    private func runNextJob() {
        guard !isBusy, !jobs.isEmpty else { return }
        isBusy = true
        let job = jobs.removeFirst()
        Task {
            await self.perform(job)
            self.isBusy = false
            self.runNextJob()
        }
    }

    private func perform(_ job: Job) async {
        switch job {
        case .conversation(let work):
            await work()
        case .announcement(let text, let style, _):
            await speak(text, style: style)
        case .powerAnnouncement:
            await announceLatestPowerState()
        }
    }

    private func announceLatestPowerState() async {
        let state = latestPowerState
        guard state != lastAnnouncedPowerState, let phrase = Self.powerPhrase(for: state) else { return }
        lastAnnouncedPowerState = state
        await speak(phrase.text, style: phrase.style)
    }

    /// Navigation-style: duck other audio, speak, restore.
    private func speak(_ text: String, style: Speaker.Style) async {
        await audio.activate(.duckOthers)
        await speaker.say(text, style: style)
        await audio.release()
    }

    private static func powerPhrase(for state: LampState) -> (text: String, style: Speaker.Style)? {
        switch state {
        case .redBreathing: return (AppConfig.Phrases.powerOn, .robot)
        case .purpleSteady: return (AppConfig.Phrases.powerOff, .assistant)
        case .redBurstFlash: return nil   // not a speed state
        }
    }
}
