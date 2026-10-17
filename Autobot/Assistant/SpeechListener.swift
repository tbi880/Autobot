// SpeechListener.swift
// Listens for one reply using Apple speech recognition (on-device when supported).
// Under CarPlay the car's microphone is used automatically.
//
//   - ends 1.5 s after the last word
//   - returns nil if nothing is said within 10 s
// The caller must activate the `.conversation` audio session first.

import AVFoundation
import Speech

final class SpeechListener {

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var timers: [Task<Void, Never>] = []
    private var silenceTimer: Task<Void, Never>?
    private var result: CheckedContinuation<String?, Never>?

    // MARK: Permissions

    /// Ask once at launch, so the prompts never appear while driving.
    static func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { @Sendable _ in }
        AVAudioApplication.requestRecordPermission { @Sendable _ in }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: Listening

    /// Returns the transcribed reply, or nil if nothing was said.
    func listen() async -> String? {
        guard Self.isAuthorized, let recognizer = Self.makeRecognizer() else { return nil }
        return await withCheckedContinuation { continuation in
            result = continuation
            do {
                try start(with: recognizer)
            } catch {
                print("Listening failed:", error)
                finish()
            }
        }
    }

    private func start(with recognizer: SFSpeechRecognizer) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        // Microphone -> recognizer
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw ListenerError.noMicrophone }
        nonisolated(unsafe) let audioSink = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            audioSink.append(buffer)
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            onMain { self.handle(text: text, isFinal: isFinal, failed: failed) }
        }

        timers = [
            after(AppConfig.Listening.noSpeechTimeout) { [weak self] in
                if self?.transcript.isEmpty == true { self?.finish() }   // nothing said
            },
            after(AppConfig.Listening.maxListeningTime) { [weak self] in
                self?.finish()
            },
        ]
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        if let text, !text.isEmpty {
            transcript = text
            // Restart the end-of-speech countdown on every new word
            silenceTimer?.cancel()
            silenceTimer = after(AppConfig.Listening.endOfSpeechSilence) { [weak self] in
                self?.finish()
            }
        }
        if isFinal || failed { finish() }
    }

    private func finish() {
        guard let continuation = result else { return }
        result = nil

        timers.forEach { $0.cancel() }
        timers = []
        silenceTimer?.cancel()
        silenceTimer = nil

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil

        let reply = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        continuation.resume(returning: reply.isEmpty ? nil : reply)
    }

    // MARK: Helpers

    private func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    private static func makeRecognizer() -> SFSpeechRecognizer? {
        for id in AppConfig.Listening.localeIdentifiers {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)), recognizer.isAvailable {
                return recognizer
            }
        }
        return nil
    }

    private enum ListenerError: Error {
        case noMicrophone
    }
}
