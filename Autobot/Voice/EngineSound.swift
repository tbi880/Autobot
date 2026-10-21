// EngineSound.swift
// The start-up sound for the ENGINE START button, synthesised in code (no audio files):
//
//   0.00 s  relay click
//   0.12 s  starter motor cranking ("ruh-ruh-ruh")
//   0.95 s  the engine fires: first bangs, rev flare to ~4600 rpm
//   then    settles into a lumpy V8 idle, with exhaust crackle on the overrun and a
//           throttle blip every few seconds
//
// It keeps idling until stop() is called (BootSequence stops it once car audio is connected).
// It plays through this app's audio session (AudioSessionManager.Mode.engineSound), so it comes
// out of whatever the current output is: the phone speaker, or the car once CarPlay connects.
// The timeline is AppConfig.Boot.crankStart / catchTime, shared with the haptics and animation.

import AVFoundation
import os

final class EngineSoundPlayer {

    private enum State { case idle, preparing, running, stopping, stopped }

    private let audio: AudioSessionManager
    private let synth = EngineSynth()
    private var state = State.idle
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var restarting = false

    init(audio: AudioSessionManager) {
        self.audio = audio
    }

    var isPlaying: Bool { state == .preparing || state == .running }

    /// Activates the audio session and starts a silent engine, so play() is instant.
    /// Called when a finger touches the button.
    func prepare() async {
        guard state == .idle else { return }
        state = .preparing
        await audio.activate(.engineSound)
        guard state == .preparing else { return }      // stopped meanwhile
        let started = await startEngine()
        if state == .preparing { state = started ? .running : .stopped }
    }

    /// Starts the start-up sequence (preparing first if that hasn't happened yet).
    func play() async {
        synth.trigger()
        await prepare()
    }

    /// Fades out, stops and releases the audio session. Returns once it is silent.
    /// The player can't be restarted.
    func stop(fadeOut: Double) async {
        guard isPlaying else { return }
        let wasRunning = state == .running
        state = .stopping
        if wasRunning {
            synth.fadeOut(seconds: fadeOut)
            try? await Task.sleep(for: .seconds(fadeOut + 0.05))
        }
        await tearDownEngine()
        await audio.release()
        state = .stopped
    }

    // MARK: Engine
    // Starting and stopping AVAudioEngine can block for a noticeable moment (especially while
    // the route switches to CarPlay), so both run off the main thread: the animation keeps going.

    private func startEngine() async -> Bool {
        let engine = AVAudioEngine()
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = hardwareRate > 0 ? hardwareRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return false
        }
        synth.setSampleRate(sampleRate)

        let synth = self.synth
        let source = AVAudioSourceNode(format: format) { @Sendable _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            synth.render(into: first, frames: frames)
            for index in buffers.indices.dropFirst() {
                buffers[index].mData?.copyMemory(from: first, byteCount: frames * MemoryLayout<Float>.size)
            }
            return 0
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = AppConfig.Boot.engineVolume
        engine.prepare()

        nonisolated(unsafe) let starting = engine
        let started = await Self.offMain { () -> Bool in
            do {
                try starting.start()
                return true
            } catch {
                print("Engine sound error:", error)
                return false
            }
        }
        guard started else { return false }
        guard state == .preparing || state == .running else {   // stopped while starting
            await Self.offMain { starting.stop() }
            return false
        }
        self.engine = engine

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        return true
    }

    /// The output changed (e.g. CarPlay or headphones connected) and the engine stopped itself:
    /// rebuild it on the new output. The synth keeps its place, so the sound just carries on.
    private func outputChanged() {
        guard state == .running, !restarting else { return }
        restarting = true
        Task {
            await tearDownEngine()
            if state == .running {
                let started = await startEngine()
                if !started && state == .running { state = .stopped }
            }
            restarting = false
        }
    }

    private func tearDownEngine() async {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { return }
        self.engine = nil
        nonisolated(unsafe) let stopping = engine
        await Self.offMain { stopping.stop() }
    }

    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: work()) }
        }
    }
}

// MARK: - Synth

/// Generates the samples on the audio render thread. The main thread only flips the
/// trigger / fade-out flags (under a lock); everything else belongs to the render thread.
nonisolated final class EngineSynth: @unchecked Sendable {

    private nonisolated struct Control: Sendable {
        var triggered = false
        var fadeOutSeconds: Double?
    }

    private nonisolated struct Cue {
        var rpm: Double
        var throttle: Double
        var starter: Double
    }

    private let control = OSAllocatedUnfairLock(initialState: Control())

    // Render-thread state
    private var sampleRate = 48_000.0
    private var time = 0.0
    private var rpm = 0.0
    private var throttle = 0.0
    private var starterLevel = 0.0
    private var gain = 1.0
    private var firePhase = 0.0
    private var cylinder = 0
    private var firings = 0
    private var pulseAmp = 0.0
    private var compressionPhase = 0.0
    private var whinePhase = 0.0
    private var lopePhase = 0.0
    private var whineLP = 0.0
    private var grindLP = 0.0
    private var noiseLP = 0.0
    private var tone1 = 0.0
    private var tone2 = 0.0
    private var crackle = 0.0
    private var crackleLP = 0.0
    private var dcIn = 0.0
    private var dcOut = 0.0
    private var seed: UInt32 = 0x9E37_79B9

    /// Cross-plane V8 firing order gives uneven pulses: that's the "burble".
    private let cylinderLevels: [Double] = [1.0, 0.72, 0.94, 0.66, 1.0, 0.8, 0.88, 0.62]

    /// Throttle blips while idling: (start within the cycle, length, peak rpm).
    private static let blips: [(at: Double, length: Double, rpm: Double)] = [
        (0.8, 0.16, 3300),
        (3.9, 0.12, 2500),
        (4.3, 0.22, 4300),
    ]
    private static let blipCycle = 7.0
    private static let firstBlip = 2.6        // seconds after the engine fires
    private static let idleRPM = 880.0

    func trigger() { control.withLock { $0.triggered = true } }

    func fadeOut(seconds: Double) { control.withLock { $0.fadeOutSeconds = max(seconds, 0.01) } }

    /// Only while the engine is stopped.
    func setSampleRate(_ rate: Double) { sampleRate = rate }

    // MARK: Script

    private static func cue(at t: Double) -> Cue {
        if t < AppConfig.Boot.crankStart { return Cue(rpm: 0, throttle: 0, starter: 0) }
        if t < AppConfig.Boot.catchTime { return Cue(rpm: 220, throttle: 0, starter: 1) }
        let s = t - AppConfig.Boot.catchTime
        if s < 0.32 { return Cue(rpm: 4600, throttle: 1, starter: 0) }       // first rev flare
        let idle = Cue(rpm: idleRPM, throttle: 0.08, starter: 0)
        guard s >= firstBlip else { return idle }
        let cycleIndex = Int((s - firstBlip) / blipCycle)
        let c = (s - firstBlip) - Double(cycleIndex) * blipCycle
        for (index, blip) in blips.enumerated() {
            if index == 0 && cycleIndex % 2 == 1 { continue }               // a bit of variety
            if c >= blip.at && c < blip.at + blip.length {
                return Cue(rpm: blip.rpm, throttle: 1, starter: 0)
            }
        }
        return idle
    }

    // MARK: Render

    func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let flags = control.withLock { $0 }
        guard flags.triggered else {
            out.update(repeating: 0, count: frames)
            return
        }

        let sr = sampleRate
        let dt = 1 / sr
        let fadeStep = flags.fadeOutSeconds.map { dt / $0 }
        let aCrank = 1 - exp(-dt / 0.05)
        let aRise = 1 - exp(-dt / 0.09)
        let aFall = 1 - exp(-dt / 0.42)
        let aThrottle = 1 - exp(-dt / 0.03)
        let aStarter = 1 - exp(-dt / 0.05)
        let aGain = 1 - exp(-dt / 0.02)
        let aTone = Self.onePole(700 + rpm * 0.35 + throttle * 1800, sr)
        let aNoise = Self.onePole(900 + rpm * 0.4 + throttle * 1600, sr)
        let aWhine = Self.onePole(1600, sr)
        let aGrind = Self.onePole(2400, sr)
        let aCrackle = Self.onePole(3800, sr)
        let crackleDecay = exp(-dt / 0.011)
        let twoPi = 2 * Double.pi

        for i in 0..<frames {
            let cue = Self.cue(at: time)
            throttle += (cue.throttle - throttle) * aThrottle
            starterLevel += (cue.starter - starterLevel) * aStarter
            let follow = cue.starter > 0 ? aCrank : (cue.rpm > rpm ? aRise : aFall)
            rpm += (cue.rpm - rpm) * follow

            lopePhase += 1.3 * dt
            if lopePhase >= 1 { lopePhase -= 1 }
            let effectiveRPM = rpm * (1 + 0.035 * sin(twoPi * lopePhase))

            var direct = 0.0      // goes straight to the output
            var body = 0.0        // goes through the exhaust tone filter and saturation

            // Relay click, then the starter solenoid thud
            if time < 0.02 {
                let e = exp(-time / 0.003)
                direct += (white() * 0.6 + sin(twoPi * 1900 * time) * 0.4) * e * 0.7
            }
            let ts = time - AppConfig.Boot.crankStart
            if ts >= 0 && ts < 0.15 {
                direct += sin(twoPi * 85 * ts) * exp(-ts / 0.035) * 0.6
            }

            // Starter motor: whine + gear grind, surging with each compression stroke
            if starterLevel > 0.001 {
                compressionPhase += rpm / 60 * 2 * dt
                if compressionPhase >= 1 { compressionPhase -= 1 }
                let surge = 0.5 + 0.5 * sin(twoPi * compressionPhase)
                whinePhase += (210 + 90 * surge) * dt
                if whinePhase >= 1 { whinePhase -= 1 }
                let whine = (2 * whinePhase - 1) * 0.7 + sin(twoPi * whinePhase * 3) * 0.3
                whineLP += (whine - whineLP) * aWhine
                grindLP += (white() - grindLP) * aGrind
                let p = compressionPhase
                let thumpEnvelope = exp(-p * 6) - exp(-p * 40)
                let thump = thumpEnvelope * (sin(twoPi * 95 * time) * 0.8 + white() * 0.3)
                direct += starterLevel * (whineLP * 0.28 * (0.6 + 0.4 * surge)
                                          + grindLP * 0.6 * (0.5 + 0.5 * surge))
                body += starterLevel * thump * 0.8
            }

            // Combustion: 8 cylinders, 4-stroke = 4 firings per revolution
            if time >= AppConfig.Boot.catchTime {
                firePhase += effectiveRPM / 15 * dt
                if firePhase >= 1 {
                    firePhase -= 1
                    cylinder = (cylinder + 1) & 7
                    let firstBangs = firings < 6 ? 1.7 : 1.0
                    firings += 1
                    pulseAmp = cylinderLevels[cylinder] * (0.85 + 0.3 * nextRandom()) * firstBangs
                    // Overrun crackle: off the throttle while the revs drop
                    if cue.throttle < 0.05, rpm > 1500, cue.rpm < rpm - 300, nextRandom() < 0.2 {
                        crackle = 0.8 + 0.7 * nextRandom()
                    }
                }
                let p = firePhase
                let pulse = (exp(-p * 12) - exp(-p * 70)) * 1.9
                let load = 0.35 + 0.65 * throttle
                noiseLP += (white() - noiseLP) * aNoise
                body += pulse * pulseAmp * load
                body += noiseLP * (pulse * 0.9 + 0.15) * (0.45 + 0.55 * throttle) * 1.4
            }

            // Exhaust: two-pole low-pass, then saturation (more throttle = more growl)
            tone1 += (body - tone1) * aTone
            tone2 += (tone1 - tone2) * aTone
            let drive = 2.4 + 2.4 * throttle
            var sample = tanh(tone2 * drive) * 0.8 + direct

            crackle *= crackleDecay
            crackleLP += (white() * crackle - crackleLP) * aCrackle
            sample += crackleLP * 1.2

            // DC blocker / gentle high-pass (~75 Hz), so phone speakers get the audible part
            let blocked = sample - dcIn + 0.99 * dcOut
            dcIn = sample
            dcOut = blocked

            if let fadeStep {
                gain = max(0, gain - fadeStep)
            } else {
                gain += (1 - gain) * aGain
            }
            out[i] = Float(max(-1, min(1, blocked * gain * 1.1)))
            time += dt
        }
    }

    // MARK: Helpers

    private static func onePole(_ cutoff: Double, _ sampleRate: Double) -> Double {
        1 - exp(-2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate)
    }

    /// 0…1, xorshift (allocation-free, fine for the audio thread).
    private func nextRandom() -> Double {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Double(seed) / Double(UInt32.max)
    }

    private func white() -> Double { nextRandom() * 2 - 1 }
}
