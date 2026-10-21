// SpeechListener.swift
// Listens for one reply using Apple speech recognition (on-device when supported),
// in several languages at once (AppConfig.Listening.languages: English + Mandarin).
// Only the voice should count, so the microphone uses Apple's voice processing (echo
// cancellation + noise suppression) and low-confidence words are dropped as noise.
// The same microphone audio goes to one recogniser per language; every language that
// heard something returns a Transcript, and the caller decides which one to use.
// Under CarPlay the car's microphone is used automatically.
//
//   - ends 1.5 s after the last word (in any language)
//   - returns [] if nothing is said within 10 s
// The caller must activate the `.conversation` audio session first.

import AVFoundation
import Speech

/// What one language's recogniser heard.
nonisolated struct Transcript {
    let text: String
    let localeID: String
    /// Average word confidence 0…1 (0 if the recogniser didn't report one).
    let confidence: Float
}

final class SpeechListener {

    /// One recogniser + its request, for one language.
    private final class Channel {
        let localeID: String
        let recognizer: SFSpeechRecognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var text = ""
        var confidence: Float = 0
        var isDone = false

        init(localeID: String, recognizer: SFSpeechRecognizer) {
            self.localeID = localeID
            self.recognizer = recognizer
            request.shouldReportPartialResults = true
            request.taskHint = .search
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
        }
    }

    private let engine = AVAudioEngine()
    private var channels: [Channel] = []
    private var timers: [Task<Void, Never>] = []
    private var silenceTimer: Task<Void, Never>?
    private var isFinishing = false
    private var result: CheckedContinuation<[Transcript], Never>?

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

    /// Returns what each language heard (empty if nothing was said).
    func listen() async -> [Transcript] {
        guard Self.isAuthorized else { return [] }
        channels = Self.makeChannels()
        guard !channels.isEmpty else { return [] }
        isFinishing = false

        return await withCheckedContinuation { continuation in
            result = continuation
            do {
                try start()
            } catch {
                print("Listening failed:", error)
                complete()
            }
        }
    }

    private func start() throws {
        // Microphone -> every language's recogniser
        let input = engine.inputNode
        enableVoiceProcessing(on: input)                // before reading the format: it can change it
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw ListenerError.noMicrophone }
        nonisolated(unsafe) let sinks = channels.map(\.request)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            for sink in sinks { sink.append(buffer) }
        }
        engine.prepare()
        try engine.start()

        for (index, channel) in channels.enumerated() {
            channel.task = channel.recognizer.recognitionTask(with: channel.request) {
                @Sendable [weak self] result, error in
                guard let self else { return }
                let isFinal = result?.isFinal ?? false
                let text = result.map {
                    isFinal ? Self.confidentText($0.bestTranscription) : $0.bestTranscription.formattedString
                }
                let confidence = result.map { Self.averageConfidence($0.bestTranscription) } ?? 0
                let failed = error != nil
                onMain {
                    self.handle(channel: index, text: text, isFinal: isFinal,
                                confidence: confidence, failed: failed)
                }
            }
        }

        timers = [
            after(AppConfig.Listening.noSpeechTimeout) { [weak self] in
                guard let self else { return }
                if self.channels.allSatisfy({ $0.text.isEmpty }) { self.stopListening() }   // nothing said
            },
            after(AppConfig.Listening.maxListeningTime) { [weak self] in
                self?.stopListening()
            },
        ]
    }

    private func handle(channel index: Int, text: String?, isFinal: Bool, confidence: Float, failed: Bool) {
        guard result != nil, channels.indices.contains(index) else { return }
        let channel = channels[index]

        if isFinal, let text {
            channel.text = text                          // final, noise words removed (may be empty)
        } else if let text, !text.isEmpty, text != channel.text {
            channel.text = text
            if !isFinishing {
                // Restart the end-of-speech countdown whenever any language hears a new word
                silenceTimer?.cancel()
                silenceTimer = after(AppConfig.Listening.endOfSpeechSilence) { [weak self] in
                    self?.stopListening()
                }
            }
        }
        if isFinal { channel.confidence = confidence }
        if isFinal || failed { channel.isDone = true }

        if channels.allSatisfy(\.isDone) {
            if isFinishing { complete() } else { stopListening() }
        }
    }

    /// Stops the microphone and asks every recogniser for its final result
    /// (final results are more accurate and carry confidence scores).
    private func stopListening() {
        guard !isFinishing, result != nil else { return }
        isFinishing = true
        cancelTimers()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        channels.forEach { $0.request.endAudio() }

        if channels.allSatisfy({ $0.text.isEmpty }) || channels.allSatisfy(\.isDone) {
            complete()
        } else {
            timers = [after(AppConfig.Listening.finalResultTimeout) { [weak self] in self?.complete() }]
        }
    }

    private func complete() {
        guard let continuation = result else { return }
        result = nil
        cancelTimers()
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        channels.forEach { $0.task?.cancel() }

        let transcripts = channels.compactMap { channel -> Transcript? in
            let text = channel.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil
                : Transcript(text: text, localeID: channel.localeID, confidence: channel.confidence)
        }
        channels = []
        continuation.resume(returning: transcripts)
    }

    // MARK: Helpers

    private func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers = []
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    /// One channel per configured language, using the first available locale of each.
    private static func makeChannels() -> [Channel] {
        AppConfig.Listening.languages.compactMap { locales in
            for id in locales {
                if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)), recognizer.isAvailable {
                    return Channel(localeID: id, recognizer: recognizer)
                }
            }
            return nil
        }
    }

    /// Voice processing: echo cancellation, noise suppression, automatic gain.
    /// If the device refuses, listening continues without it.
    private func enableVoiceProcessing(on input: AVAudioInputNode) {
        guard AppConfig.Listening.voiceProcessing, !input.isVoiceProcessingEnabled else { return }
        do {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = true
            input.isVoiceProcessingBypassed = false
        } catch {
            print("Voice processing unavailable:", error)
        }
    }

    /// The final transcription without words below AppConfig.Listening.minWordConfidence.
    /// Works on character ranges, so Chinese (no spaces between words) stays intact.
    private nonisolated static func confidentText(_ transcription: SFTranscription) -> String {
        let minimum = AppConfig.Listening.minWordConfidence
        let text = NSMutableString(string: transcription.formattedString)
        for segment in transcription.segments.reversed()
        where segment.confidence > 0 && segment.confidence < minimum {
            text.replaceCharacters(in: segment.substringRange, with: "")
        }
        return (text as String)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private nonisolated static func averageConfidence(_ transcription: SFTranscription) -> Float {
        let segments = transcription.segments
        guard !segments.isEmpty else { return 0 }
        return segments.map(\.confidence).reduce(0, +) / Float(segments.count)
    }

    private enum ListenerError: Error {
        case noMicrophone
    }
}
