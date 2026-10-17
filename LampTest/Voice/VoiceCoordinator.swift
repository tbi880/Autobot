// VoiceCoordinator.swift
// Guarantees that only one voice interaction plays at a time.
//
// Priority:
//   1. The welcome conversation always goes first.
//   2. Power Mode announcements wait until it is over. If the speed state flips
//      several times meanwhile, only the latest state is announced, and nothing is
//      said if the lamp ends up back in the last announced state.

import Foundation

final class VoiceCoordinator {

    private nonisolated enum Job {
        case conversation(@MainActor () async -> Void)
        case powerAnnouncement
        case voiceTest(LampState)

        var isAnnouncement: Bool {
            if case .powerAnnouncement = self { return true }
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

    /// Queues a conversation ahead of any pending Power Mode announcement.
    func runConversation(_ work: @escaping @MainActor () async -> Void) {
        let firstAnnouncement = jobs.firstIndex(where: \.isAnnouncement) ?? jobs.count
        jobs.insert(.conversation(work), at: firstAnnouncement)
        runNextJob()
    }

    /// Queues "Power Mode Activated/Deactivated" for the given state.
    func announcePowerChange(to state: LampState) {
        latestPowerState = state
        if !jobs.contains(where: \.isAnnouncement) {
            jobs.append(.powerAnnouncement)
        }
        runNextJob()
    }

    /// Debug: plays the Power Mode phrase for `state` now, without changing what has been announced.
    func testPowerVoice(for state: LampState) {
        jobs.append(.voiceTest(state))
        runNextJob()
    }

    // MARK: Queue

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
        case .powerAnnouncement:
            await announceLatestPowerState()
        case .voiceTest(let state):
            await speakPowerPhrase(for: state)
        }
    }

    private func announceLatestPowerState() async {
        let state = latestPowerState
        guard state != lastAnnouncedPowerState else { return }
        lastAnnouncedPowerState = state
        await speakPowerPhrase(for: state)
    }

    private func speakPowerPhrase(for state: LampState) async {
        await audio.activate(.duckOthers)
        switch state {
        case .redBreathing: await speaker.say(AppConfig.Phrases.powerOn, style: .assistant)
        case .purpleSteady: await speaker.say(AppConfig.Phrases.powerOff, style: .assistant)
        }
        await audio.release()
    }
}
