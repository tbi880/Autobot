// MetallicVoiceEffect.swift
// Turns rendered speech into a clear "metallic robot" voice, entirely in code:
//
//   1. comb filter   - a very short echo fed back into itself; gives the hollow, metal-tube ring
//   2. ring modulator - mixes in a little of the voice multiplied by a sine wave; adds the robotic buzz
//   3. loudness      - normalises the peak and soft-limits, so it sounds a bit louder than the
//                      normal voice without clipping
//
// Pitch shift and a touch of plate reverb are added afterwards by the player (Speaker.swift).
// All strengths are in AppConfig.RobotVoice; lower them if the words get hard to understand.

import AVFoundation

nonisolated enum MetallicVoiceEffect {

    /// Joins the rendered buffers into one buffer and applies the effect.
    /// Expects 32-bit float, non-interleaved buffers (see AudioFormatting.toFloat32).
    static func process(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let format = buffers.first?.format else { return nil }
        let speechFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        let tailFrames = Int(format.sampleRate * 0.15)      // room for the comb filter to ring out
        let totalFrames = speechFrames + tailFrames
        guard speechFrames > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))
        else { return nil }
        output.frameLength = AVAudioFrameCount(totalFrames)

        for channel in 0..<Int(format.channelCount) {
            guard let samples = output.floatChannelData?[channel] else { continue }
            var signal = concatenate(buffers, channel: channel, totalFrames: totalFrames)
            signal = combFilter(signal, sampleRate: format.sampleRate)
            signal = ringModulate(signal, sampleRate: format.sampleRate)
            signal = louden(signal)
            signal.withUnsafeBufferPointer { samples.update(from: $0.baseAddress!, count: totalFrames) }
        }
        return output
    }

    // MARK: Steps

    private static func concatenate(_ buffers: [AVAudioPCMBuffer], channel: Int, totalFrames: Int) -> [Float] {
        var signal = [Float](repeating: 0, count: totalFrames)
        var position = 0
        for buffer in buffers {
            let sourceChannel = min(channel, Int(buffer.format.channelCount) - 1)
            guard let source = buffer.floatChannelData?[sourceChannel] else { continue }
            for i in 0..<Int(buffer.frameLength) where position + i < totalFrames {
                signal[position + i] = source[i]
            }
            position += Int(buffer.frameLength)
        }
        return signal
    }

    /// y[n] = x[n] + feedback * y[n - delay], blended with the dry voice.
    private static func combFilter(_ x: [Float], sampleRate: Double) -> [Float] {
        let delay = max(1, Int(sampleRate * AppConfig.RobotVoice.combDelayMs / 1000))
        let feedback = AppConfig.RobotVoice.combFeedback
        let mix = AppConfig.RobotVoice.combMix
        var wet = [Float](repeating: 0, count: x.count)
        for n in 0..<x.count {
            wet[n] = x[n] + (n >= delay ? feedback * wet[n - delay] : 0)
        }
        // (1 - feedback) keeps the resonant part from getting much louder than the dry voice
        return (0..<x.count).map { n in x[n] * (1 - mix) + wet[n] * (1 - feedback) * mix }
    }

    /// Blends in the signal multiplied by a sine carrier.
    private static func ringModulate(_ x: [Float], sampleRate: Double) -> [Float] {
        let frequency = AppConfig.RobotVoice.ringModHz
        let mix = AppConfig.RobotVoice.ringModMix
        return x.enumerated().map { n, sample in
            let carrier = Float(sin(2 * Double.pi * frequency * Double(n) / sampleRate))
            return sample * (1 - mix) + sample * carrier * mix
        }
    }

    /// Normalises the peak to full scale and soft-limits with tanh (louder, no clipping).
    private static func louden(_ x: [Float]) -> [Float] {
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return x }
        let drive = AppConfig.RobotVoice.drive
        let gain = drive / peak
        let normaliser = tanh(drive)
        return x.map { tanh($0 * gain) / normaliser }
    }
}
