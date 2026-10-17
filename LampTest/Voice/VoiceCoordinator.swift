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

    private enum Job {
        case conversation(@MainActor () async -> Void)
        case powerAnnouncement
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
        let firstAnnouncement = jobs.firstIndex(where: Self.isAnnouncement) ?? jobs.count
        jobs.insert(.conversation(work), at: firstAnnouncement)
        runNextJob()
    }

    /// Queues "Power Mode Activated/Deactivated" for the given state.
    func announcePowerChange(to state: LampState) {
        latestPowerState = state
        if !jobs.contains(where: Self.isAnnouncement) {
            jobs.append(.powerAnnouncement)
        }
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
        }
    }

    private func announceLatestPowerState() async {
        let state = latestPowerState
        guard state != lastAnnouncedPowerState else { return }
        lastAnnouncedPowerState = state

        audio.activate(.duckOthers)
        switch state {
        case .redBreathing: await speaker.say(AppConfig.Phrases.powerOn, style: .robot)
        case .purpleSteady: await speaker.say(AppConfig.Phrases.powerOff, style: .assistant)
        }
        audio.release()
    }

    private static func isAnnouncement(_ job: Job) -> Bool {
        if case .powerAnnouncement = job { return true }
        return false
    }
}
