// SpeechListener.swift
// Listens for one reply using Apple's speech recognition (network processing allowed),
// in Mandarin only (AppConfig.Listening.locale).
// Only the voice should count, so the microphone uses Apple's voice processing (echo
// cancellation + noise suppression) and low-confidence words are dropped as noise.
// Under CarPlay the car's microphone is used automatically.
//
//   - ends 1.5 s after the last word
//   - returns nil if nothing is said within 10 s
// The caller must activate the `.conversation` audio session first.

import AVFoundation
import Speech

/// What the recogniser heard.
nonisolated struct Transcript {
    let text: String
    let localeID: String
    /// Average word confidence 0…1 (0 if the recogniser didn't report one).
    let confidence: Float
}

/// Callable from any thread (recognition callbacks, audio taps): it only reads a constant and prints.
nonisolated enum SpeechDiagnosticLog {
    private static let startUptime = ProcessInfo.processInfo.systemUptime

    static func write(_ message: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startUptime
        print(String(format: "[SpeechDiagnostic +%.3fs] %@", elapsed, message))
    }
}

final class SpeechListener {

    /// Samples input level without retaining or recording microphone audio.
    private final class AudioInputProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var bufferCount = 0
        private var lastReport: UInt64 = 0

        func report(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }

            bufferCount += 1
            let now = DispatchTime.now().uptimeNanoseconds
            guard bufferCount == 1 || now - lastReport >= 1_000_000_000 else { return }
            lastReport = now

            var rms = 0.0
            var peak = 0.0
            if let samples = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                if count > 0 {
                    var sumSquares = 0.0
                    for index in 0..<count {
                        let value = Double(samples[index])
                        sumSquares += value * value
                        peak = max(peak, abs(value))
                    }
                    rms = sqrt(sumSquares / Double(count))
                }
            }
            let message = "mic buffer #\(bufferCount): frames=\(buffer.frameLength), bytes=\(buffer.audioBufferList.pointee.mBuffers.mDataByteSize), rms=\(String(format: "%.5f", rms)), peak=\(String(format: "%.5f", peak))"
            DispatchQueue.global(qos: .utility).async {
                SpeechDiagnosticLog.write(message)
            }
        }
    }

    /// The Mandarin recogniser + its request, for one reply.
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
            // Allow Apple to use server-side recognition when available, which can be
            // more accurate than an on-device-only request.
            request.requiresOnDeviceRecognition = false
        }
    }

    /// A fresh engine for every reply, torn down afterwards: a voice-processing engine left
    /// behind keeps failing to render ("vpio render err -1") once the audio session moves on.
    private var engine: AVAudioEngine?
    private var channel: Channel?
    private var timers: [Task<Void, Never>] = []
    private var silenceTimer: Task<Void, Never>?
    private var isFinishing = false
    private var result: CheckedContinuation<Transcript?, Never>?

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

    /// Returns what was heard (nil if nothing was said).
    func listen(contextualStrings: [String] = []) async -> Transcript? {
        SpeechDiagnosticLog.write("listen requested; speechAuth=\(SFSpeechRecognizer.authorizationStatus().rawValue), micPermission=\(AVAudioApplication.shared.recordPermission.rawValue)")
        guard Self.isAuthorized else {
            SpeechDiagnosticLog.write("listen aborted: missing speech or microphone permission")
            return nil
        }
        guard let channel = Self.makeChannel() else {
            SpeechDiagnosticLog.write("listen aborted: \(AppConfig.Listening.locale) recognizer unavailable")
            return nil
        }
        self.channel = channel
        SpeechDiagnosticLog.write("recognizer: \(channel.localeID) available=\(channel.recognizer.isAvailable) onDeviceSupported=\(channel.recognizer.supportsOnDeviceRecognition) onDeviceRequired=\(channel.request.requiresOnDeviceRecognition)")
        let hints = Array(contextualStrings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(100))
        channel.request.contextualStrings = hints
        SpeechDiagnosticLog.write("configured \(hints.count) saved-place recognition hint(s)")
        isFinishing = false

        return await withCheckedContinuation { continuation in
            result = continuation
            do {
                try start(channel)
            } catch {
                SpeechDiagnosticLog.write("listening failed while starting engine: \(error)")
                complete()
            }
        }
    }

    private func start(_ channel: Channel) throws {
        // Microphone -> the recogniser
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        enableVoiceProcessing(on: input)                // before reading the format: it can change it
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw ListenerError.noMicrophone }
        SpeechDiagnosticLog.write("starting audio engine: sampleRate=\(format.sampleRate), channels=\(format.channelCount), voiceProcessingEnabled=\(input.isVoiceProcessingEnabled)")
        nonisolated(unsafe) let sink = channel.request
        let probe = AudioInputProbe()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            probe.report(buffer)
            sink.append(buffer)
        }
        engine.prepare()
        try engine.start()
        SpeechDiagnosticLog.write("audio engine started")

        channel.task = channel.recognizer.recognitionTask(with: channel.request) {
            @Sendable [weak self] result, error in
            guard let self else { return }
            let isFinal = result?.isFinal ?? false
            let rawText = result?.bestTranscription.formattedString
            let text = result.map {
                isFinal ? Self.confidentText($0.bestTranscription) : $0.bestTranscription.formattedString
            }
            let confidence = result.map { Self.averageConfidence($0.bestTranscription) } ?? 0
            let failed = error != nil
            let confidenceText = result.map { _ in String(format: "%.3f", confidence) } ?? "n/a (no recognition result)"
            SpeechDiagnosticLog.write("callback \(channel.localeID): final=\(isFinal), confidence=\(confidenceText), raw=\(rawText ?? "<nil>"), returned=\(text ?? "<nil>"), error=\(error.map { "\($0)" } ?? "<none>")")
            onMain {
                self.handle(channel, text: text, isFinal: isFinal,
                            confidence: confidence, failed: failed)
            }
        }

        timers = [
            after(AppConfig.Listening.noSpeechTimeout) { [weak self] in
                guard let self else { return }
                if self.channel?.text.isEmpty ?? true {
                    SpeechDiagnosticLog.write("no-speech timeout after \(AppConfig.Listening.noSpeechTimeout)s; heard=\(self.heardSummary)")
                    self.stopListening(reason: "no-speech timeout")
                }
            },
            after(AppConfig.Listening.maxListeningTime) { [weak self] in
                SpeechDiagnosticLog.write("maximum listening time reached")
                self?.stopListening(reason: "maximum listening time")
            },
        ]
    }

    private func handle(_ channel: Channel, text: String?, isFinal: Bool, confidence: Float, failed: Bool) {
        guard result != nil, channel === self.channel else { return }   // ignore late callbacks from an earlier reply

        if isFinal, let text {
            channel.text = text                          // final, noise words removed (may be empty)
        } else if let text, !text.isEmpty, text != channel.text {
            channel.text = text
            if !isFinishing {
                // Restart the end-of-speech countdown whenever a new word is heard
                silenceTimer?.cancel()
                silenceTimer = after(AppConfig.Listening.endOfSpeechSilence) { [weak self] in
                    SpeechDiagnosticLog.write("end-of-speech silence timeout after \(AppConfig.Listening.endOfSpeechSilence)s; heard=\(self?.heardSummary ?? "<listener released>")")
                    self?.stopListening(reason: "end-of-speech silence timeout")
                }
            }
        }
        if isFinal { channel.confidence = confidence }
        if isFinal || failed { channel.isDone = true }

        if channel.isDone {
            if isFinishing { complete() } else { stopListening(reason: "recognizer finished") }
        }
    }

    /// Stops the microphone and asks the recogniser for its final result
    /// (final results are more accurate and carry confidence scores).
    private func stopListening(reason: String) {
        guard !isFinishing, result != nil, let channel else { return }
        SpeechDiagnosticLog.write("stopping listening: reason=\(reason), heard=\(heardSummary)")
        isFinishing = true
        cancelTimers()

        tearDownEngine()
        channel.request.endAudio()

        if channel.text.isEmpty || channel.isDone {
            complete()
        } else {
            timers = [after(AppConfig.Listening.finalResultTimeout) { [weak self] in self?.complete() }]
        }
    }

    private func complete() {
        guard let continuation = result else { return }
        result = nil
        cancelTimers()
        tearDownEngine()
        channel?.task?.cancel()

        var transcript: Transcript?
        if let channel {
            let text = channel.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                transcript = Transcript(text: text, localeID: channel.localeID, confidence: channel.confidence)
            }
        }
        SpeechDiagnosticLog.write(transcript.map {
            "completed: \($0.localeID) confidence=\(String(format: "%.3f", $0.confidence)) text=\($0.text)"
        } ?? "completed with no transcript")
        channel = nil
        continuation.resume(returning: transcript)
    }

    private var heardSummary: String {
        guard let channel else { return "<no recognizer>" }
        return "\(channel.localeID)=\(channel.text.isEmpty ? "<empty>" : channel.text)"
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

    /// The Mandarin recogniser (AppConfig.Listening.locale), or nil if it isn't available.
    private static func makeChannel() -> Channel? {
        let id = AppConfig.Listening.locale
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)), recognizer.isAvailable else {
            return nil
        }
        return Channel(localeID: id, recognizer: recognizer)
    }

    /// Stops the microphone, switches voice processing off and drops the engine.
    private func tearDownEngine() {
        guard let engine else { return }
        self.engine = nil
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(false)
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
        let filtered = (text as String)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if filtered.isEmpty {
            let raw = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                SpeechDiagnosticLog.write("confidence filter removed every word; preserving raw transcript (average confidence=\(String(format: "%.3f", Self.averageConfidence(transcription))))")
                return raw
            }
        }
        return filtered
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
