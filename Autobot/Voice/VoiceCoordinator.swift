// VoiceCoordinator.swift
// The single place everything goes through to speak, so only one voice plays at a time.
//
// Queue order:
//   1. Urgent announcements (e.g. "Door open detected") go to the front of the queue.
//   2. The welcome conversation comes next.
//   3. Normal announcements (including Power Mode) wait their turn.
// Something already playing is never cut off.
//
// Every announcement is spoken navigation-style: other apps' audio is ducked, not paused.

import Foundation

final class VoiceCoordinator {

    private nonisolated enum Job {
        case conversation(@MainActor () async -> Void)
        case announcement(String, Speaker.Style, urgent: Bool)

        var isUrgent: Bool {
            if case .announcement(_, _, urgent: true) = self { return true }
            return false
        }
    }

    private let audio: AudioSessionManager
    private let speaker: Speaker

    private var jobs: [Job] = []
    private var isBusy = false

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

    /// Queues a conversation ahead of normal announcements
    /// (but behind urgent ones already waiting).
    func runConversation(_ work: @escaping @MainActor () async -> Void) {
        let firstNormal = jobs.firstIndex { !$0.isUrgent && !Self.isConversation($0) } ?? jobs.count
        jobs.insert(.conversation(work), at: firstNormal)
        runNextJob()
    }

    /// "Power Mode Activated" (red breathing) or "Power Mode Deactivated" (purple steady).
    func announcePowerChange(to state: LampState) {
        guard let phrase = Self.powerPhrase(for: state) else { return }
        announce(phrase.text, style: phrase.style)
    }

    /// Debug: same as announcePowerChange.
    func testPowerVoice(for state: LampState) {
        announcePowerChange(to: state)
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
        }
    }

    /// Navigation-style: duck other audio, speak, restore.
    private func speak(_ text: String, style: Speaker.Style) async {
        await audio.activate(.duckOthers)
        await speaker.say(text, style: style)
        await audio.release()
    }

    private static func powerPhrase(for state: LampState) -> (text: String, style: Speaker.Style)? {
        switch state {
        case .redBreathing: return (AppConfig.Phrases.powerOn, .sciFi)
        case .purpleSteady: return (AppConfig.Phrases.powerOff, .assistant)
        case .redBurstFlash: return nil   // not a speed state
        }
    }
}
