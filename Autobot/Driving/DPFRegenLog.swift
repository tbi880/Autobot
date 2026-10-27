// DPFRegenLog.swift
// Autobot's own record of DPF regenerations: when each one happened, how far the car went since the one
// before, the soot before it and (when both ends were seen) how long it took. Kept on the phone.
//
//   while live data runs: every AppConfig.DPF.logInterval, 7E0 220432 (count), 220434 (distance since
//   the last regeneration), 22042C (soot), 220380 (status) between two rounds — or, while the DPF screen
//   is open, its own reads (DPFMonitor -> observe)
//   -> the count goes up (or, on a PCM without the count, the distance drops back to ~0)
//   -> an entry with the highest distance seen before it
//
// It only knows regenerations from its first reading on; the PCM's own last-10 history is
// DPFHistoryFinder's job. In test mode (simulated DPF values) entries stay in memory only.

import Combine
import Foundation

private typealias Tuning = AppConfig.DPF

final class DPFRegenLog: ObservableObject {

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        /// When it was noticed (the count went up / the distance reset).
        var date: Date
        /// The PCM's regeneration count after it.
        var count: Int?
        /// Distance driven since the regeneration before it, km (the last distance read before it).
        var intervalKm: Double?
        /// Soot before it, g/L.
        var sootBefore: Double?
        /// How long it ran, when its start and end were both seen (minutes).
        var durationMinutes: Double?
        /// The last reading before it was long before (another drive): the distance is a lower bound.
        var approximate: Bool
        /// Regenerations the count skipped (happened while nothing was read); their distances are unknown.
        var missed: Int = 0
    }

    /// Newest first.
    @Published private(set) var entries: [Entry] = []
    /// The latest values read: count and distance since the last regeneration.
    @Published private(set) var lastCount: Int?
    @Published private(set) var lastDistance: Double?
    @Published private(set) var lastRead: Date?

    var onLog: ((String) -> Void)?

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
        var seen: Date?
        var regenStart: Date?
        var sootAtRegenStart: Double?
        var distanceAtRegenStart: Double?
    }

    private let obd: OBDAdapter
    private let persist = !AppConfig.TestMode.enabled
    private var state = State()
    private var task: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

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

    /// Delete everything recorded.
    func clear() {
        entries = []
        save()
        onLog?("DPF log: cleared")
    }

    // MARK: Readings

    /// A reading (from the poll here or from DPFMonitor). nil values are ones not read / not answered.
    func observe(count: Int?, distance: Double?, soot: Double?, regenerating: Bool?, at date: Date = Date()) {
        guard count != nil || distance != nil || regenerating != nil else { return }
        var s = state
        let previousSeen = s.seen

        if regenerating == true, s.regenStart == nil {
            s.regenStart = date
            s.sootAtRegenStart = s.soot ?? soot
            s.distanceAtRegenStart = s.peakDistance ?? s.distance
        }

        // Did a regeneration happen since the last reading? The count is preferred; the distance falling
        // back is only used on a PCM that doesn't give the count.
        var happened = false
        var missed = 0
        if let count, let old = s.count, count > old {
            happened = true
            missed = count - old - 1
        } else if count == nil, s.count == nil, let distance, let old = s.peakDistance ?? s.distance,
                  old >= 20, distance < old - 10 {
            happened = true
        }

        if happened {
            let watchedStart = s.regenStart != nil && s.distanceAtRegenStart != nil
            var interval: Double? = s.distanceAtRegenStart ?? s.peakDistance
            if interval == nil { interval = s.distance }
            if missed > 0 { interval = nil }
            var stale = true
            if let previousSeen { stale = date.timeIntervalSince(previousSeen) > Tuning.logApproximateAfter }
            var entry = Entry(date: date, count: count, intervalKm: interval,
                              sootBefore: s.sootAtRegenStart ?? s.soot,
                              approximate: !watchedStart && stale, missed: max(missed, 0))
            if regenerating == false, let start = s.regenStart {
                entry.durationMinutes = date.timeIntervalSince(start) / 60
            }
            entries.insert(entry, at: 0)
            if entries.count > Tuning.logMaxEntries { entries.removeLast(entries.count - Tuning.logMaxEntries) }
            onLog?("DPF log: regeneration recorded · " + Self.describe(entry))
            s.peakDistance = nil
            if regenerating != true {                         // finished already: nothing left to time
                s.regenStart = nil
                s.sootAtRegenStart = nil
                s.distanceAtRegenStart = nil
            } else if s.regenStart == nil {
                s.regenStart = date                           // counted at its start: time it from here
            }
        }

        if regenerating == false, let start = s.regenStart {
            // Ended: the newest entry gets its duration if the count went up during this regeneration.
            if !happened, let first = entries.first, first.durationMinutes == nil,
               first.date >= start.addingTimeInterval(-60) {
                entries[0].durationMinutes = date.timeIntervalSince(start) / 60
                onLog?(String(format: "DPF log: the regeneration took %.1f min", entries[0].durationMinutes ?? 0))
            }
            s.regenStart = nil
            s.sootAtRegenStart = nil
            s.distanceAtRegenStart = nil
        }

        if let count { s.count = count }
        if let distance {
            s.distance = distance
            s.peakDistance = max(s.peakDistance ?? 0, distance)
        }
        if let soot { s.soot = soot }
        s.seen = date
        state = s
        lastCount = s.count
        lastDistance = s.distance
        lastRead = date
        save()
    }

    // MARK: Polling while driving

    private func liveDataChanged(_ ready: Bool) {
        task?.cancel()
        task = nil
        guard ready else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: Tuning.logFirstDelay)
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Tuning.logInterval)
            }
        }
    }

    private func poll() async {
        guard !fedByMonitor, obd.isReady else { return }
        let values: [MazdaDPF.Value] = [.regenCount, .regenDistance, .soot, .regenStatus]
        let replies: [MazdaDPF.Value: [UInt8]]? = await obd.runBetweenRounds { adapter in
            var replies: [MazdaDPF.Value: [UInt8]] = [:]
            for value in values {
                if let data = await adapter.readDID(value.did, from: MazdaDPF.header, complete: false,
                                                    timeout: AppConfig.OBD.replyTimeout) {
                    replies[value] = data
                }
            }
            return replies
        }
        guard let replies, !fedByMonitor else { return }
        var reading = DPFReading()
        for (value, data) in replies { reading.apply(value, data: data) }
        observe(count: reading.regenCount, distance: reading.regenDistance, soot: reading.soot,
                regenerating: reading.regenerating)
    }

    // MARK: Helpers

    /// "312 km · soot 6.10 g/L · 14.5 min" for the log.
    static func describe(_ entry: Entry) -> String {
        var parts: [String] = []
        if let km = entry.intervalKm {
            parts.append(String(format: entry.approximate ? "≥ %.0f km" : "%.0f km", km))
        } else {
            parts.append("distance unknown")
        }
        if entry.missed > 0 { parts.append("\(entry.missed) more missed") }
        if let soot = entry.sootBefore { parts.append(String(format: "soot %.2f g/L", soot)) }
        if let minutes = entry.durationMinutes { parts.append(String(format: "%.1f min", minutes)) }
        if let count = entry.count { parts.append("#\(count)") }
        return parts.joined(separator: " · ")
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
