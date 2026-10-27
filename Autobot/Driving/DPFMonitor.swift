// DPFMonitor.swift
// Live DPF (diesel particulate filter) monitoring while the DPF screen is open: engine RPM and the
// DPF back pressure (differential pressure) on every read, for the charts, plus soot, regeneration
// and exhaust temperatures one at a time in turn (AppConfig.DPF.rotation). Values and scaling:
// MazdaDPF.swift.
//
//   screen opens -> start() -> while open:
//     OBDAdapter.runBetweenRounds { RPM (01 0C) + 7E0 22F47A + the next slow value }
//     -> reading (latest values), points (chart history), regeneration start / end -> log
//   screen closes -> stop()
//
// Nothing is read while the screen is closed, so normal driving keeps its full live-data rate.
// In test mode (AppConfig.TestMode, no OBD session) it shows simulated values instead, built as raw
// bytes and decoded by MazdaDPF like real replies.

import Combine
import Foundation

private typealias Tuning = AppConfig.DPF

final class DPFMonitor: ObservableObject {

    /// One read for the charts.
    struct Point: Identifiable, Equatable {
        let id: Int
        let time: Date
        let rpm: Double?
        /// Differential pressure, kPa.
        let pressure: Double?
        let regenerating: Bool
    }

    @Published private(set) var isRunning = false
    @Published private(set) var reading = DPFReading()
    /// Chart history, oldest first (AppConfig.DPF.historySeconds).
    @Published private(set) var points: [Point] = []
    @Published private(set) var status = "Not monitoring"
    /// Values the PCM didn't answer: not asked again while the screen stays open.
    @Published private(set) var unanswered: Set<MazdaDPF.Value> = []
    /// Highest differential pressure since the screen was opened, kPa.
    @Published private(set) var peakPressure: Double?
    /// Reads per second, over the last few seconds.
    @Published private(set) var readRate: Double?
    /// When the regeneration in progress started (or was first seen); nil while none is running.
    @Published private(set) var regenStartedAt: Date?

    /// Start, stop, regenerations and values the PCM doesn't answer, for the dashboard log.
    var onLog: ((String) -> Void)?
    /// The values read in each round (only those, not the ones carried over), for the regeneration log.
    var onValues: ((DPFReading) -> Void)?

    private let obd: OBDAdapter
    private var task: Task<Void, Never>?
    private var nextID = 0
    private var misses: [MazdaDPF.Value: Int] = [:]
    private var rotationIndex = 0
    private var recentReads: [Date] = []

    init(obd: OBDAdapter) {
        self.obd = obd
    }

    // MARK: Actions

    /// Starts reading (the DPF screen opened). The latest slow values stay on screen until they're read
    /// again; RPM, pressure and the chart start fresh.
    func start() {
        guard task == nil else { return }
        points = []
        peakPressure = nil
        misses = [:]
        unanswered = []
        rotationIndex = 0
        recentReads = []
        readRate = nil
        reading.rpm = nil
        reading.pressure = nil
        isRunning = true
        logLine("DPF monitor: started")
        task = Task { [weak self] in
            if AppConfig.TestMode.enabled {
                await self?.simulate()
            } else {
                await self?.monitor()
            }
        }
    }

    /// Stops reading (the DPF screen closed).
    func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        isRunning = false
        status = "Not monitoring"
        var line = "DPF monitor: stopped"
        if let peakPressure { line += String(format: " · peak back pressure %.2f kPa", peakPressure) }
        if let soot = reading.soot { line += String(format: " · soot %.2f g/L", soot) }
        logLine(line)
    }

    // MARK: Reading

    private struct Round {
        var rpm: Double?
        var pressure: [UInt8]?
        var slow: [UInt8]?
    }

    private func monitor() async {
        while !Task.isCancelled {
            guard obd.isReady else {
                status = "Waiting for live data (adapter connected, ignition on)…"
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let slow = nextSlowValue()
            let readPressure = !unanswered.contains(.pressure)
            let started = ContinuousClock.now
            let round = await obd.runBetweenRounds { adapter in
                await Self.read(adapter, pressure: readPressure, slow: slow)
            }
            guard !Task.isCancelled else { return }
            guard let round else {                      // live data stopped meanwhile
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            handle(round, readPressure: readPressure, slow: slow)
            let wait = Tuning.minInterval - (ContinuousClock.now - started)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
    }

    /// One read, with the adapter to itself (between two live-data rounds).
    private static func read(_ adapter: OBDAdapter, pressure: Bool, slow: MazdaDPF.Value?) async -> Round {
        var round = Round()
        round.rpm = await adapter.readRPM()
        if pressure {
            round.pressure = await adapter.readDID(MazdaDPF.Value.pressure.did, from: MazdaDPF.header,
                                                   complete: true, timeout: AppConfig.OBD.replyTimeout)
        }
        if let slow {
            round.slow = await adapter.readDID(slow.did, from: MazdaDPF.header, complete: slow.isMultiFrame,
                                               timeout: AppConfig.OBD.replyTimeout)
        }
        return round
    }

    /// The next value of the rotation the PCM hasn't refused; nil if it refuses them all.
    private func nextSlowValue() -> MazdaDPF.Value? {
        let rotation = Tuning.rotation
        guard !rotation.isEmpty else { return nil }
        for _ in 0..<rotation.count {
            let value = rotation[rotationIndex % rotation.count]
            rotationIndex += 1
            if !unanswered.contains(value) { return value }
        }
        return nil
    }

    private func handle(_ round: Round, readPressure: Bool, slow: MazdaDPF.Value?) {
        var next = reading
        next.rpm = round.rpm
        var pressureNow: Double?
        if readPressure {
            var answered = false
            if let data = round.pressure { answered = next.apply(.pressure, data: data) }
            if answered { pressureNow = next.pressure?.differential }
            note(.pressure, answered: answered)
        }
        var fresh = DPFReading()
        if let slow {
            var answered = false
            if let data = round.slow {
                answered = next.apply(slow, data: data)
                fresh.apply(slow, data: data)
            }
            note(slow, answered: answered)
        }
        onValues?(fresh)
        let before = reading.regenerating
        reading = next
        trackRegeneration(from: before, to: next.regenerating)
        append(rpm: round.rpm, pressure: pressureNow)
        updateStatus()
    }

    /// Counts a value the PCM didn't answer; after a few in a row it isn't asked again.
    private func note(_ value: MazdaDPF.Value, answered: Bool) {
        if answered {
            misses[value] = 0
            return
        }
        misses[value, default: 0] += 1
        guard misses[value, default: 0] >= Tuning.missesBeforeSkipping, !unanswered.contains(value) else { return }
        unanswered.insert(value)
        logLine("DPF monitor: \(value.label) (\(MazdaDPF.header) 22\(value.did)) not answered; "
                + "not asked again while the screen is open")
    }

    // MARK: History and events

    private func append(rpm: Double?, pressure: Double?) {
        let now = Date()
        points.append(Point(id: nextID, time: now, rpm: rpm, pressure: pressure,
                            regenerating: reading.regenerating == true))
        nextID += 1
        let oldest = now.addingTimeInterval(-Tuning.historySeconds)
        if let first = points.first, first.time < oldest {
            points.removeAll { $0.time < oldest }
        }
        if let pressure, pressure > (peakPressure ?? -.infinity) { peakPressure = pressure }
        recentReads.append(now)
        recentReads.removeAll { now.timeIntervalSince($0) > 5 }
        if let first = recentReads.first, recentReads.count > 1 {
            let span = now.timeIntervalSince(first)
            readRate = span > 0 ? Double(recentReads.count - 1) / span : nil
        }
    }

    private func trackRegeneration(from before: Bool?, to now: Bool?) {
        guard let now, now != before else { return }
        if now {
            regenStartedAt = Date()
            var line = before == nil ? "DPF: regeneration in progress" : "DPF: regeneration started"
            if let soot = reading.soot { line += String(format: " · soot %.2f g/L", soot) }
            if let distance = reading.regenDistance { line += String(format: " · %.0f km since the last one", distance) }
            logLine(line)
        } else {
            if let started = regenStartedAt {
                let minutes = Date().timeIntervalSince(started) / 60
                var line = String(format: "DPF: regeneration finished after %.1f min (while watched)", minutes)
                if let soot = reading.soot { line += String(format: " · soot %.2f g/L", soot) }
                logLine(line)
            }
            regenStartedAt = nil
        }
    }

    private func updateStatus() {
        var parts = ["Live"]
        if let readRate { parts.append(String(format: "%.1f reads/s", readRate)) }
        if unanswered.contains(.pressure) { parts.append("back pressure not answered by the PCM") }
        status = parts.joined(separator: "  ·  ")
    }

    private func logLine(_ message: String) {
        onLog?(message)
    }

    // MARK: Test mode

    /// Simulated readings (no car): RPM wandering between idle and 3000, back pressure growing with
    /// RPM and soot, soot building up until a regeneration burns it off. Built as raw bytes and decoded
    /// by MazdaDPF, like real replies.
    private func simulate() async {
        var sim = Simulation()
        while !Task.isCancelled {
            let step = sim.step(seconds: Tuning.simulationInterval.inSeconds)
            var next = reading
            next.rpm = step.rpm
            for (value, data) in step.raw { next.apply(value, data: data) }
            var fresh = next
            fresh.raw = [:]
            onValues?(fresh)
            let before = reading.regenerating
            reading = next
            trackRegeneration(from: before, to: next.regenerating)
            append(rpm: step.rpm, pressure: next.pressure?.differential)
            status = "Test mode: simulated values, no car"
            try? await Task.sleep(for: Tuning.simulationInterval)
        }
    }

    private struct Simulation {
        var time = 0.0
        var soot = 5.4             // g/L
        var generated = 4.8        // g/L since the last regeneration
        var distance = 287.0       // km since the last regeneration
        var count = 412
        var regenerating = false
        var egt = 210.0            // °C, follows its target slowly

        mutating func step(seconds: Double) -> (rpm: Double, raw: [(MazdaDPF.Value, [UInt8])]) {
            time += seconds
            let cruise = 1600 + 900 * sin(time / 9) + 350 * sin(time / 2.3)
            let rpm = max(760, cruise + Double.random(in: -60...60))
            let speedKmh = max(0, (rpm - 800) / 25)
            distance += speedKmh * seconds / 3600 * 40     // sped up so the demo moves
            if regenerating {
                soot = max(0.3, soot - 0.05 * seconds * 4)
                if soot <= 0.35 { regenerating = false; generated = 0; distance = 0; count += 1 }
            } else {
                soot += 0.004 * seconds * 4
                generated += 0.004 * seconds * 4
                if soot >= 6.2 { regenerating = true }
            }
            let target = regenerating ? 620.0 : 180 + rpm / 15
            egt += (target - egt) * min(1, seconds / 6)
            let flow = rpm / 1000
            let pressure = 0.25 + flow * flow * (0.55 + soot * 0.09) + Double.random(in: -0.08...0.08)

            var raw: [(MazdaDPF.Value, [UInt8])] = []
            let dp = Self.bytes16(Int(pressure * 100))
            raw.append((.pressure, [0x01] + dp))
            raw.append((.soot, Self.bytes16(Int(soot * 65536 / 100))))
            raw.append((.sootGenerated, Self.bytes16(Int(generated * 65536 / 100))))
            raw.append((.regenStatus, [regenerating ? 0x02 : 0x00]))
            raw.append((.regenCount, Self.bytes16(count)))
            let d = Int(distance * 640)
            raw.append((.regenDistance, [0x00, UInt8((d >> 16) & 0xFF), UInt8((d >> 8) & 0xFF), UInt8(d & 0xFF)]))
            let temps = [egt + 40, egt + 15, egt - 10].map { Self.bytes16(Int(($0 + 40) * 10)) }
            raw.append((.exhaustTemps, [0x07] + temps.flatMap { $0 }))
            raw.append((.dpfTemps, [0x03] + Self.bytes16(Int((egt + 40) * 10)) + Self.bytes16(Int((egt + 15) * 10))))
            raw.append((.coolant, [UInt8(88 + 40)]))
            return (rpm, raw)
        }

        private static func bytes16(_ value: Int) -> [UInt8] {
            let v = UInt16(truncatingIfNeeded: value)
            return [UInt8(v >> 8), UInt8(v & 0xFF)]
        }
    }
}

private extension Duration {
    /// The duration in seconds, as a Double.
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
