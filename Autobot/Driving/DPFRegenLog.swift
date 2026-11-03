// DPFRegenLog.swift
// Autobot's own record of DPF regenerations, kept on the phone. Each regeneration is one entry, from
// the moment the PCM's flag comes on to the moment its count goes up (completed) — or until it stops
// without the count going up (interrupted: engine switched off, or the flag off for a while on the
// move). For each one: when, how long, the distance driven since the one before, the odometer, the soot
// load before and after, the peak / mean exhaust and DPF temperatures, the fuel-in-oil value before and
// after (if the PCM gives it) and the average speed.
//
//   while live data runs (screen closed), between two rounds:
//     every regenCheckInterval  7E0 220380 (flag)
//     every logInterval         + 220432 count, 220434 distance, 22042C / 22042B soot
//     while a regeneration runs + soot, F478 / F47C temperatures, count, odometer, oil dilution
//   while the DPF screen is open: its own reads (DPFMonitor -> observe)
//
// When the regeneration ended (MazdaDPF.swift, community findings for the SKYACTIV-D 2.2):
//   - completed: 220432 goes up (or, on a PCM without the count, 220434 drops back to ~0)
//   - the flag drops while the car is stopped although the regeneration carries on, so that alone
//     isn't an end: only off for AppConfig.DPF.regenOffConfirm while moving, or the engine switched
//     off, without the count going up, is "interrupted". The PCM usually starts again next drive.
// A regeneration that happened while nothing was read is still found from the count (approximate).
//
// The PCM's own last-10 history is DPFHistoryFinder's job. In test mode entries stay in memory only.

import Combine
import Foundation

private typealias Tuning = AppConfig.DPF

final class DPFRegenLog: ObservableObject {

    enum Outcome: String, Codable {
        case completed, interrupted
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        /// When it ended (or was noticed: the count went up / the distance reset).
        var date: Date
        /// The PCM's regeneration count after it.
        var count: Int?
        /// Distance driven since the regeneration before it, km (the last distance read before it).
        var intervalKm: Double?
        /// Soot accumulated (PM_ACC) before it, g/L.
        var sootBefore: Double?
        /// How long it ran, when its start was seen (minutes).
        var durationMinutes: Double?
        /// The last reading before it was long before (another drive): the distance is a lower bound.
        var approximate: Bool
        /// Regenerations the count skipped (happened while nothing was read); their distances are unknown.
        var missed: Int = 0

        // Recorded since the regeneration flag is followed from start to end (nil in older entries).
        var outcome: Outcome?
        var started: Date?
        /// Soot load (PM_ACC_DSD) before / after, and PM_ACC after, g/L.
        var sootDesiredBefore: Double?
        var sootDesiredAfter: Double?
        var sootAfter: Double?
        /// Soot generated (PM_GEN) when it started, g/L.
        var sootGeneratedBefore: Double?
        /// Hottest exhaust gas / DPF inlet temperature and the mean exhaust temperature while it ran, °C.
        var peakExhaustTemp: Double?
        var peakDPFInletTemp: Double?
        var meanExhaustTemp: Double?
        /// Odometer at the start / end, km.
        var odometerStart: Double?
        var odometerEnd: Double?
        /// Fuel-in-oil value (220 3E1, raw: unit unproven) before / after.
        var oilDilutionBefore: Double?
        var oilDilutionAfter: Double?
        /// Average road speed while it ran, km/h.
        var averageSpeed: Double?

        /// Distance driven while it ran, km.
        var distanceDuring: Double? {
            guard let a = odometerStart, let b = odometerEnd, b >= a else { return nil }
            return b - a
        }
    }

    /// A regeneration being followed right now.
    struct Active: Codable, Equatable {
        var start: Date
        var countAtStart: Int?
        var distanceBefore: Double?
        var sootBefore: Double?
        var sootDesiredBefore: Double?
        var sootGeneratedBefore: Double?
        var odometerStart: Double?
        var oilDilutionBefore: Double?
        var peakExhaustTemp: Double?
        var peakDPFInletTemp: Double?
        var exhaustTempSum = 0.0
        var exhaustTempReads = 0
        var speedSum = 0.0
        var speedReads = 0
        /// The flag has been off since then while moving (nil: on, or off only while stopped).
        var flagOffSince: Date?
        /// Live data stopped (engine off) while it was running.
        var engineOffAt: Date?
        /// Its start was seen (not just found running after a gap).
        var watched: Bool
    }

    /// Newest first.
    @Published private(set) var entries: [Entry] = []
    /// The regeneration being followed, for the DPF screen; nil while none.
    @Published private(set) var active: Active?
    /// The latest values read: count and distance since the last regeneration.
    @Published private(set) var lastCount: Int?
    @Published private(set) var lastDistance: Double?
    @Published private(set) var lastRead: Date?

    var onLog: ((String) -> Void)?
    /// A regeneration started (or was found running): once per regeneration, not again within
    /// AppConfig.DPF.regenAnnounceCooldown.
    var onRegenerationStarted: (() -> Void)?

    /// While true (the DPF screen is open) the log doesn't poll: the monitor's reads come in through
    /// observe.
    var fedByMonitor = false

    /// What was known at the last reading, kept on the phone so a regeneration between two drives is
    /// still noticed.
    private struct State: Codable {
        var count: Int?
        var distance: Double?
        /// Highest distance since the last regeneration: still right if the distance resets a moment
        /// before the count goes up.
        var peakDistance: Double?
        var soot: Double?
        var sootDesired: Double?
        var sootGenerated: Double?
        var odometer: Double?
        var oilDilution: Double?
        var seen: Date?
        var active: Active?
    }

    private let obd: OBDAdapter
    private let persist = !AppConfig.TestMode.enabled
    private var state = State()
    private var task: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    /// This regeneration was announced (cleared when the flag goes off or live data stops).
    private var announcedThisOne = false
    private var lastAnnounced: Date?
    /// Values the PCM didn't answer while polling: not asked again this drive.
    private var misses: [MazdaDPF.Value: Int] = [:]
    private var skipped: Set<MazdaDPF.Value> = []

    private static let entriesKey = "DPFRegenLog.entries"
    private static let stateKey = "DPFRegenLog.state"

    init(obd: OBDAdapter) {
        self.obd = obd
        if persist {
            entries = Self.load([Entry].self, key: Self.entriesKey) ?? []
            state = Self.load(State.self, key: Self.stateKey) ?? State()
            lastCount = state.count
            lastDistance = state.distance
            lastRead = state.seen
            active = state.active
        }
        obd.$isReady
            .removeDuplicates()
            .sink { [weak self] ready in self?.liveDataChanged(ready) }
            .store(in: &subscriptions)
    }

    // MARK: Statistics

    /// Average distance between regenerations over the last `count` entries with a known distance.
    func averageInterval(last count: Int = 10) -> Double? {
        let known = entries.compactMap(\.intervalKm).prefix(count)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    /// Things worth a look, for the DPF screen (AppConfig.DPF health thresholds); empty when all is well.
    func healthNotes() -> [String] {
        var notes: [String] = []
        let completed = entries.filter { $0.outcome != .interrupted }
        if let last = completed.first, let after = last.sootDesiredAfter ?? last.sootAfter,
           after >= Tuning.postRegenSootHigh {
            notes.append(String(format: "Soot still %.2f g/L after the last regeneration: ash or a clogged "
                                + "filter? Worth a check if it stays like this.", after))
        }
        let intervals = completed.prefix(Tuning.shortIntervalsInARow).compactMap(\.intervalKm)
        if intervals.count == Tuning.shortIntervalsInARow, intervals.allSatisfy({ $0 < Tuning.shortIntervalKm }) {
            notes.append(String(format: "The last %d regenerations came less than %.0f km apart (normal is "
                                + "about 250 km or more).", Tuning.shortIntervalsInARow, Tuning.shortIntervalKm))
        }
        let recent = entries.prefix(Tuning.interruptedInARow)
        if recent.count == Tuning.interruptedInARow, recent.allSatisfy({ $0.outcome == .interrupted }) {
            notes.append("\(Tuning.interruptedInARow) regenerations in a row were interrupted: each one adds "
                         + "fuel to the oil. Give the next one a longer drive.")
        }
        return notes
    }

    /// Delete everything recorded.
    func clear() {
        entries = []
        save()
        onLog?("DPF log: cleared")
    }

    // MARK: Readings

    /// A reading (from the poll here or from DPFMonitor): only the values read this time are set.
    /// `speed` is the road speed at the time, km/h.
    func observe(_ reading: DPFReading, speed: Double?, at date: Date = Date()) {
        let r = reading
        guard r.regenCount != nil || r.regenDistance != nil || r.regenerating != nil || r.soot != nil
                || r.sootDesired != nil || !r.exhaustTemps.isEmpty || r.dpfInletTemp != nil else { return }
        if r.regenerating == true {
            announceStart(at: date)
        } else if r.regenerating == false, (speed ?? 0) >= Tuning.movingSpeed {
            announcedThisOne = false
        }
        var s = state
        let previousSeen = s.seen

        // A regeneration that was running when the engine went off: the count tells whether it got
        // finished (handled below as completed); unchanged means it was interrupted.
        if let a = s.active, let off = a.engineOffAt, let count = r.regenCount,
           let atStart = a.countAtStart ?? s.count, count <= atStart {
            record(interrupted: a, at: off, reason: "engine switched off", in: &s)
        }

        // Started?
        if r.regenerating == true, s.active == nil {
            s.active = Active(start: date, countAtStart: r.regenCount ?? s.count,
                              distanceBefore: s.peakDistance ?? s.distance ?? r.regenDistance,
                              sootBefore: r.soot ?? s.soot, sootDesiredBefore: r.sootDesired ?? s.sootDesired,
                              sootGeneratedBefore: r.sootGenerated ?? s.sootGenerated,
                              odometerStart: r.odometer ?? s.odometer, oilDilutionBefore: r.oilDilution ?? s.oilDilution,
                              watched: previousSeen.map { date.timeIntervalSince($0) < Tuning.logApproximateAfter } ?? false)
            var line = "DPF log: regeneration started"
            if let soot = r.sootDesired ?? s.sootDesired { line += String(format: " · soot load %.2f g/L", soot) }
            if let km = s.active?.distanceBefore { line += String(format: " · %.0f km since the last one", km) }
            onLog?(line)
        }

        // Follow it: peaks, speed, the flag, start values read a moment later.
        if var a = s.active {
            if r.regenerating == true {
                a.flagOffSince = nil
                a.engineOffAt = nil
            } else if r.regenerating == false, let speed, speed >= Tuning.movingSpeed, a.flagOffSince == nil {
                a.flagOffSince = date
            }
            let egt = Array(r.exhaustTemps.values)
            if let hottest = egt.max() { a.peakExhaustTemp = max(a.peakExhaustTemp ?? hottest, hottest) }
            if !egt.isEmpty {
                a.exhaustTempSum += egt.reduce(0, +) / Double(egt.count)
                a.exhaustTempReads += 1
            }
            if let inlet = r.dpfInletTemp { a.peakDPFInletTemp = max(a.peakDPFInletTemp ?? inlet, inlet) }
            if let speed { a.speedSum += speed; a.speedReads += 1 }
            if a.odometerStart == nil { a.odometerStart = r.odometer }
            if a.oilDilutionBefore == nil { a.oilDilutionBefore = r.oilDilution }
            if a.sootGeneratedBefore == nil { a.sootGeneratedBefore = r.sootGenerated }
            if a.countAtStart == nil { a.countAtStart = r.regenCount }
            s.active = a
        }

        // Completed? The count is preferred; the distance falling back is only used on a PCM that
        // doesn't give the count.
        var happened = false
        var missed = 0
        if let count = r.regenCount, let old = s.active?.countAtStart ?? s.count, count > old {
            happened = true
            missed = count - old - 1
        } else if r.regenCount == nil, s.count == nil, let distance = r.regenDistance,
                  let old = s.peakDistance ?? s.distance, old >= 20, distance < old - 10 {
            happened = true
        }
        if happened {
            recordCompleted(count: r.regenCount, missed: missed, reading: r, at: date, previousSeen: previousSeen, in: &s)
        } else if let a = s.active, let off = a.flagOffSince, date.timeIntervalSince(off) >= Tuning.regenOffConfirm {
            record(interrupted: a, at: off, reason: "flag off while driving", in: &s)
        }

        if let count = r.regenCount { s.count = count }
        if let distance = r.regenDistance {
            s.distance = distance
            s.peakDistance = max(s.peakDistance ?? 0, distance)
        }
        if let soot = r.soot { s.soot = soot }
        if let soot = r.sootDesired { s.sootDesired = soot }
        if let soot = r.sootGenerated { s.sootGenerated = soot }
        if let odometer = r.odometer { s.odometer = odometer }
        if let oil = r.oilDilution { s.oilDilution = oil }
        s.seen = date
        state = s
        active = s.active
        lastCount = s.count
        lastDistance = s.distance
        lastRead = date
        save()
    }

    private func recordCompleted(count: Int?, missed: Int, reading r: DPFReading, at date: Date,
                                 previousSeen: Date?, in s: inout State) {
        let a = s.active
        var interval: Double? = a?.distanceBefore ?? s.peakDistance ?? s.distance
        if missed > 0 { interval = nil }
        var stale = true
        if let previousSeen { stale = date.timeIntervalSince(previousSeen) > Tuning.logApproximateAfter }
        let end = a?.engineOffAt ?? date
        var entry = Entry(date: end, count: count, intervalKm: interval,
                          sootBefore: a?.sootBefore ?? s.soot,
                          approximate: !(a?.watched ?? false) && stale, missed: max(missed, 0))
        entry.outcome = .completed
        if let a {
            entry.started = a.start
            entry.durationMinutes = end.timeIntervalSince(a.start) / 60
            fill(&entry, from: a)
        }
        entry.sootDesiredAfter = r.sootDesired
        entry.sootAfter = r.soot
        entry.odometerEnd = r.odometer ?? s.odometer
        entry.oilDilutionAfter = r.oilDilution
        add(entry)
        onLog?("DPF log: regeneration completed · " + Self.describe(entry))
        s.active = nil
        s.peakDistance = nil
    }

    private func record(interrupted a: Active, at end: Date, reason: String, in s: inout State) {
        var entry = Entry(date: end, count: a.countAtStart, intervalKm: nil, sootBefore: a.sootBefore,
                          approximate: !a.watched)
        entry.outcome = .interrupted
        entry.started = a.start
        entry.durationMinutes = end.timeIntervalSince(a.start) / 60
        fill(&entry, from: a)
        entry.sootDesiredAfter = s.sootDesired
        entry.sootAfter = s.soot
        entry.odometerEnd = s.odometer
        entry.oilDilutionAfter = s.oilDilution
        add(entry)
        onLog?("DPF log: regeneration interrupted (\(reason)) · " + Self.describe(entry))
        s.active = nil
    }

    private func fill(_ entry: inout Entry, from a: Active) {
        entry.sootDesiredBefore = a.sootDesiredBefore
        entry.sootGeneratedBefore = a.sootGeneratedBefore
        entry.peakExhaustTemp = a.peakExhaustTemp
        entry.peakDPFInletTemp = a.peakDPFInletTemp
        entry.meanExhaustTemp = a.exhaustTempReads > 0 ? a.exhaustTempSum / Double(a.exhaustTempReads) : nil
        entry.odometerStart = a.odometerStart
        entry.oilDilutionBefore = a.oilDilutionBefore
        entry.averageSpeed = a.speedReads > 0 ? a.speedSum / Double(a.speedReads) : nil
    }

    private func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Tuning.logMaxEntries { entries.removeLast(entries.count - Tuning.logMaxEntries) }
    }

    // MARK: Polling while driving

    private func liveDataChanged(_ ready: Bool) {
        task?.cancel()
        task = nil
        guard ready else {
            announcedThisOne = false          // engine off: a regeneration carrying on next drive is said again
            if var a = state.active, a.engineOffAt == nil {
                a.engineOffAt = Date()        // finished or not: the next count read tells
                state.active = a
                active = a
                save()
            }
            return
        }
        misses = [:]
        skipped = []
        let check = max(Tuning.regenCheckInterval.components.seconds, 1)
        let pollEvery = max(1, Int(Tuning.logInterval.components.seconds / check))
        task = Task { [weak self] in
            try? await Task.sleep(for: Tuning.logFirstDelay)
            var tick = 0
            while !Task.isCancelled {
                await self?.poll(full: tick % pollEvery == 0)
                tick += 1
                try? await Task.sleep(for: Tuning.regenCheckInterval)
            }
        }
    }

    /// One poll between two live-data rounds: the flag; the counters every `logInterval`; and while a
    /// regeneration runs, everything it's recorded with. Right after a start, the start values once more.
    private func poll(full: Bool) async {
        guard !fedByMonitor, obd.isReady else { return }
        var values: [MazdaDPF.Value] = [.regenStatus]
        if full || state.active?.engineOffAt != nil {
            values += [.regenCount, .regenDistance, .soot, .sootDesired]
        }
        if state.active != nil {
            values += [.regenCount, .soot, .sootDesired, .exhaustTemps, .dpfTemps, .odometer, .oilDilution]
        }
        let wasActive = state.active != nil
        await read(values)
        if !wasActive, state.active != nil {
            await read([.regenCount, .regenDistance, .sootGenerated, .odometer, .oilDilution, .exhaustTemps])
        }
    }

    private func read(_ wanted: [MazdaDPF.Value]) async {
        var values: [MazdaDPF.Value] = []
        for value in wanted where !values.contains(value) && !skipped.contains(value) { values.append(value) }
        guard !values.isEmpty else { return }
        let toRead = values
        let replies: [MazdaDPF.Value: [UInt8]]? = await obd.runBetweenRounds { adapter in
            var replies: [MazdaDPF.Value: [UInt8]] = [:]
            for value in toRead {
                if let data = await adapter.readDID(value.did, from: MazdaDPF.header, complete: value.isMultiFrame,
                                                    timeout: AppConfig.OBD.replyTimeout) {
                    replies[value] = data
                }
            }
            return replies
        }
        guard let replies, !fedByMonitor else { return }
        var reading = DPFReading()
        for value in toRead {
            let answered = replies[value].map { reading.apply(value, data: $0) } ?? false
            if answered {
                misses[value] = 0
            } else {
                misses[value, default: 0] += 1
                if misses[value, default: 0] >= Tuning.missesBeforeSkipping { skipped.insert(value) }
            }
        }
        observe(reading, speed: obd.sample?.speed)
    }

    /// The flag says a regeneration is running: say so, once.
    private func announceStart(at date: Date) {
        guard Tuning.announceRegeneration, !announcedThisOne else { return }
        announcedThisOne = true
        if let lastAnnounced, date.timeIntervalSince(lastAnnounced) < Tuning.regenAnnounceCooldown { return }
        lastAnnounced = date
        onLog?("DPF log: regeneration started (220380 on), announcing")
        onRegenerationStarted?()
    }

    // MARK: Helpers

    /// "312 km · soot 6.10 g/L · 14.5 min" for the log.
    static func describe(_ entry: Entry) -> String {
        var parts: [String] = []
        if entry.outcome == .interrupted {
            parts.append("interrupted")
        } else if let km = entry.intervalKm {
            parts.append(String(format: entry.approximate ? "≥ %.0f km" : "%.0f km", km))
        } else {
            parts.append("distance unknown")
        }
        if entry.missed > 0 { parts.append("\(entry.missed) more missed") }
        if let soot = entry.sootDesiredBefore ?? entry.sootBefore { parts.append(String(format: "soot %.2f g/L", soot)) }
        if let minutes = entry.durationMinutes { parts.append(String(format: "%.1f min", minutes)) }
        if let count = entry.count { parts.append("#\(count)") }
        return parts.joined(separator: " · ")
    }

    /// The second line: what the regeneration did. nil for entries without any of it.
    static func details(_ entry: Entry) -> String? {
        var parts: [String] = []
        if let before = entry.sootDesiredBefore ?? entry.sootBefore, let after = entry.sootDesiredAfter ?? entry.sootAfter {
            parts.append(String(format: "soot %.2f → %.2f g/L", before, after))
        }
        if let peak = entry.peakExhaustTemp { parts.append(String(format: "peak EGT %.0f °C", peak)) }
        if let peak = entry.peakDPFInletTemp { parts.append(String(format: "DPF in %.0f °C", peak)) }
        if let mean = entry.meanExhaustTemp { parts.append(String(format: "mean %.0f °C", mean)) }
        if let km = entry.distanceDuring { parts.append(String(format: "%.0f km driven", km)) }
        if let speed = entry.averageSpeed { parts.append(String(format: "%.0f km/h avg", speed)) }
        if let before = entry.oilDilutionBefore, let after = entry.oilDilutionAfter {
            parts.append(String(format: "oil dil. %.0f → %.0f", before, after))
        }
        if let odo = entry.odometerStart { parts.append(String(format: "odo %.0f km", odo)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func save() {
        guard persist else { return }
        Self.store(entries, key: Self.entriesKey)
        Self.store(state, key: Self.stateKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func store<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
