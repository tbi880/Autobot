// Speaker.swift
// Text-to-speech with two voices:
//   .assistant - natural female voice (welcome, questions, "Power Mode Deactivated")
//   .robot     - clear male voice with a metallic effect (MetallicVoiceEffect) + slight
//                pitch-down + plate reverb, a little louder ("Power Mode Activated")
// `say` is async and returns when the speech has finished playing.
// The caller is responsible for the audio session (see AudioSessionManager).

import AVFoundation

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {

    enum Style {
        case assistant
        case robot
    }

    private let synthesizer = AVSpeechSynthesizer()   // speaks directly
    private let renderer = AVSpeechSynthesizer()      // renders robot speech into buffers
    private let robotEffects = RobotEffectChain()
    private var speechFinished: CheckedContinuation<Void, Never>?

    /// Diagnostic messages (shown in the app's log).
    var onLog: ((String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    func say(_ text: String, style: Style = .assistant) async {
        stop()
        let utterance = Voices.utterance(text, style: style)
        switch style {
        case .assistant:
            await speakDirectly(utterance)
        case .robot:
            let buffers = await renderToBuffers(utterance)
            let voiceName = utterance.voice?.name ?? "default"
            onLog?("Robot voice: \(voiceName), \(buffers.count) audio buffers")
            if let metallic = MetallicVoiceEffect.process(buffers), await robotEffects.play(metallic) {
                onLog?("Robot voice: played with metallic effect")
            } else {
                // Effect unavailable: still say it with the same voice, just without the effect
                onLog?("Robot voice: effect failed, speaking without it")
                await speakDirectly(Voices.utterance(text, style: .robot))
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        robotEffects.stop()
        finishDirectSpeech()
    }

    // MARK: Direct speech

    private func speakDirectly(_ utterance: AVSpeechUtterance) async {
        await withCheckedContinuation { continuation in
            speechFinished = continuation
            synthesizer.speak(utterance)
        }
    }

    private func finishDirectSpeech() {
        speechFinished?.resume()
        speechFinished = nil
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        onMain { self.finishDirectSpeech() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        onMain { self.finishDirectSpeech() }
    }

    // MARK: Rendering (for the robot effects)

    private func renderToBuffers(_ utterance: AVSpeechUtterance) async -> [AVAudioPCMBuffer] {
        await withCheckedContinuation { continuation in
            let collector = BufferCollector(continuation)
            renderer.write(utterance) { @Sendable buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    collector.finish()                   // an empty buffer marks the end
                } else if let float = AudioFormatting.toFloat32(pcm) {
                    collector.append(float)
                }
            }
            // Safety net in case the end marker never arrives
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { collector.finish() }
        }
    }
}

// MARK: - Voices

@MainActor
private enum Voices {

    static func utterance(_ text: String, style: Speaker.Style) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.volume = 1.0
        switch style {
        case .assistant:
            u.voice = femaleVoice()
            u.rate = AVSpeechUtteranceDefaultSpeechRate
            u.pitchMultiplier = 1.0
        case .robot:
            u.voice = robotVoice()
            u.rate = AVSpeechUtteranceDefaultSpeechRate * AppConfig.RobotVoice.rateFactor
            u.pitchMultiplier = AppConfig.RobotVoice.pitchMultiplier
        }
        return u
    }

    /// Clearest available English male voice (premium > enhanced > any); the effect adds the robot.
    static func robotVoice() -> AVSpeechSynthesisVoice? {
        let males = AVSpeechSynthesisVoice.speechVoices().filter { $0.gender == .male }
        let american = males.filter { $0.language == "en-US" }
        let english = males.filter { $0.language.hasPrefix("en") }
        return american.first { $0.quality == .premium }
            ?? american.first { $0.quality == .enhanced }
            ?? english.first { $0.quality == .premium }
            ?? english.first { $0.quality == .enhanced }
            ?? american.first
            ?? english.first
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Best available US English female voice.
    static func femaleVoice() -> AVSpeechSynthesisVoice? {
        let females = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" && $0.gender == .female }
        return females.first { $0.quality == .premium }
            ?? females.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
            ?? females.first
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

// MARK: - Robot effect chain

/// AVAudioEngine graph: player -> pitch shift -> plate reverb -> output.
/// The metallic sound itself is baked into the buffer by MetallicVoiceEffect.
@MainActor
private final class RobotEffectChain {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let reverb = AVAudioUnitReverb()

    init() {
        pitch.pitch = AppConfig.RobotVoice.pitchCents
        reverb.loadFactoryPreset(.plate)
        reverb.wetDryMix = AppConfig.RobotVoice.reverbMix
        player.volume = AppConfig.RobotVoice.volume
        [player, pitch, reverb].forEach { engine.attach($0) }
    }

    /// Plays the buffer. Returns false if the audio engine couldn't start.
    func play(_ buffer: AVAudioPCMBuffer) async -> Bool {
        let format = buffer.format
        engine.stop()
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        do {
            engine.prepare()
            try engine.start()
        } catch {
            print("Robot voice engine error:", error)
            return false
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
                continuation.resume()
            }
            player.play()
        }

        try? await Task.sleep(for: .milliseconds(400))   // let the reverb tail ring out
        engine.stop()
        return true
    }

    func stop() {
        player.stop()   // also fires the pending completion handler
        engine.stop()
    }
}

// MARK: - Helpers

/// Collects rendered buffers from a background thread and delivers them once.
private nonisolated final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    init(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) {
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { buffers.append(buffer) }
    }

    func finish() {
        lock.withLock {
            continuation?.resume(returning: buffers)
            continuation = nil
        }
    }
}

nonisolated enum AudioFormatting {
    /// Speech buffers are often 16-bit integers; audio effect nodes need 32-bit float.
    static func toFloat32(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        if source.commonFormat == .pcmFormatFloat32 && !source.isInterleaved { return buffer }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: source.sampleRate,
                                         channels: source.channelCount,
                                         interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength)
        else { return nil }
        do {
            try converter.convert(to: output, from: buffer)
            return output
        } catch {
            return nil
        }
    }
}
