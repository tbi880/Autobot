// DPFHistoryFinder.swift
// Finds where the PCM keeps the distances of its last 10 DPF regenerations ("DPF regeneration distance
// 01–10" in Mazda's dealer tool; the DID isn't published) and reads them. How:
//
//   1. Scan (car parked, ignition on, a few minutes): which PCM DIDs answer in
//      AppConfig.DPF.historyScanPlan? Each one is read to the end; replies of 10+ bytes are candidates,
//      kept on the phone with the regeneration count at the time.
//   2. Later, after a regeneration (the count went up), every candidate is read again (automatically:
//      when the DPF screen opens, and when the regeneration log records one). The history moves along
//      by one entry per regeneration — a new distance in front, the oldest one gone — so the candidate
//      that shifted that way is it, and is used from then on. A candidate that changes without a
//      regeneration is ruled out.
//   "Use" picks one by hand before that.
//
// Entries are read as 1 byte each, ×AppConfig.DPF.historyKmPerUnit km (as the Torque preset for the
// SkyActiv-D shows them), or 2 bytes each in km when the reply holds 20 bytes.

import Combine
import Foundation

private typealias Tuning = AppConfig.DPF

final class DPFHistoryFinder: ObservableObject {

    struct Candidate: Codable, Identifiable, Equatable {
        var header: String
        var did: String
        /// The reply when it was last compared.
        var bytes: [UInt8]
        var readAt: Date
        /// The regeneration count when `bytes` was read.
        var regenCount: Int?
        /// true: shifted by one entry after a regeneration (it's the history); false: changed without one.
        var verdict: Bool?
        /// How the shift went, once seen: bytes per entry, and whether the newest entry is first.
        var entryWidth: Int?
        var newestFirst: Bool?
        /// Times it was re-read after a regeneration without having shifted.
        var unshiftedChecks = 0

        var id: String { "\(header) \(did)" }
    }

    /// The history in use.
    struct Learned: Codable, Equatable {
        var header: String
        var did: String
        var entryWidth: Int
        var newestFirst: Bool
        /// true when found by the shift after a regeneration, false when picked by hand.
        var confirmed: Bool
    }

    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case reading
    }

    @Published private(set) var phase: Phase = .idle
    /// Best first.
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var learned: Learned?
    /// The PCM's history in km, newest first; nil until read.
    @Published private(set) var history: [Double]?
    @Published private(set) var historyRaw: [UInt8]?
    @Published private(set) var historyRead: Date?
    @Published private(set) var message = ""

    var onLog: ((String) -> Void)?

    var isBusy: Bool { phase != .idle }

    private let obd: OBDAdapter
    private var cancelRequested = false

    private static let candidatesKey = "DPFHistoryFinder.candidates"
    private static let learnedKey = "DPFHistoryFinder.learned"
    private static let rawKey = "DPFHistoryFinder.raw"
    private static let readKey = "DPFHistoryFinder.read"

    init(obd: OBDAdapter) {
        self.obd = obd
        candidates = Self.load([Candidate].self, key: Self.candidatesKey) ?? []
        learned = Self.load(Learned.self, key: Self.learnedKey)
        if let raw = UserDefaults.standard.data(forKey: Self.rawKey), let learned {
            historyRaw = [UInt8](raw)
            history = Self.decode([UInt8](raw), learned)
            historyRead = UserDefaults.standard.object(forKey: Self.readKey) as? Date
        }
        message = nextStep
    }

    // MARK: Actions

    func scan() { Task { await runScan() } }
    func cancel() { cancelRequested = true }

    /// Reads the history in use, and re-reads the candidates to see which shifted after a regeneration.
    /// Quietly does nothing without live data.
    func refresh() { Task { await runRefresh() } }

    /// Use this candidate as the history (before a regeneration has confirmed it).
    func use(_ candidate: Candidate) {
        let width = candidate.entryWidth ?? (candidate.bytes.count >= Tuning.historyEntries * 2 ? 2 : 1)
        setLearned(Learned(header: candidate.header, did: candidate.did, entryWidth: width,
                           newestFirst: candidate.newestFirst ?? true, confirmed: candidate.verdict == true),
                   bytes: candidate.bytes)
        onLog?("DPF history: \(candidate.id) picked by hand")
    }

    func forget() {
        learned = nil
        history = nil
        historyRaw = nil
        historyRead = nil
        for key in [Self.learnedKey, Self.rawKey, Self.readKey] { UserDefaults.standard.removeObject(forKey: key) }
        message = nextStep
        onLog?("DPF history: forgotten")
    }

    /// Forget the scan result (and the history in use).
    func resetCandidates() {
        candidates = []
        save()
        forget()
    }

    // MARK: Scan

    private struct ScanResult {
        var candidates: [Candidate]
        var answered: Int
    }

    private func runScan() async {
        guard !isBusy else { return }
        guard obd.isReady else {
            message = "Connect the adapter and switch the ignition on first"
            return
        }
        if let speed = obd.sample?.speed, speed >= 1 {
            message = "Park the car first"
            return
        }
        let plan = Tuning.historyScanPlan
        cancelRequested = false
        phase = .scanning(done: 0, total: 1)
        message = "Scanning the PCM… live data pauses for a few minutes"
        let result: ScanResult? = await obd.runBetweenRounds { [self] adapter in
            let keys = await adapter.scanDIDs(plan, timeout: Tuning.historyScanTimeout,
                                              progress: { done, total in phase = .scanning(done: done, total: total) },
                                              cancelled: { cancelRequested })
            phase = .reading
            let count = await Self.readCount(adapter)
            let known = Set(MazdaDPF.Value.allCases.map(\.did))
            var found: [Candidate] = []
            for key in keys {
                if cancelRequested { break }
                let parts = key.split(separator: " ").map(String.init)
                guard parts.count == 2, !known.contains(parts[1]) else { continue }
                if let bytes = await adapter.readDID(parts[1], from: parts[0], complete: true,
                                                     timeout: AppConfig.OBD.replyTimeout),
                   bytes.count >= Tuning.historyEntries {
                    found.append(Candidate(header: parts[0], did: parts[1], bytes: bytes, readAt: Date(),
                                           regenCount: count))
                }
            }
            return ScanResult(candidates: found, answered: keys.count)
        }
        phase = .idle
        if cancelRequested {
            message = "Scan cancelled"
            return
        }
        guard let result else {
            message = "Live data stopped during the scan — check the adapter and try again"
            return
        }
        candidates = result.candidates.sorted { Self.score($0) > Self.score($1) }
        save()
        onLog?("DPF history: \(result.answered) PCM DIDs answer, \(candidates.count) long enough: "
               + candidates.map { "\($0.did) (\($0.bytes.count) B)" }.joined(separator: ", "))
        message = candidates.isEmpty
            ? "No PCM DID in the scanned range returns 10 or more bytes. Widen AppConfig.DPF.historyScanPlan."
            : nextStep
    }

    // MARK: Refresh

    private struct RefreshResult {
        var replies: [String: [UInt8]]
        var count: Int?
    }

    private func runRefresh() async {
        guard !isBusy, obd.isReady else { return }
        var keys: [(header: String, did: String)] = []
        if let learned { keys.append((learned.header, learned.did)) }
        for candidate in candidates where candidate.verdict == nil {
            if !keys.contains(where: { $0.header == candidate.header && $0.did == candidate.did }) {
                keys.append((candidate.header, candidate.did))
            }
        }
        guard !keys.isEmpty else { return }
        phase = .reading
        let toRead = keys
        let result: RefreshResult? = await obd.runBetweenRounds { adapter in
            var replies: [String: [UInt8]] = [:]
            for key in toRead {
                if let bytes = await adapter.readDID(key.did, from: key.header, complete: true,
                                                     timeout: AppConfig.OBD.replyTimeout) {
                    replies["\(key.header) \(key.did)"] = bytes
                }
            }
            let count = await Self.readCount(adapter)
            return RefreshResult(replies: replies, count: count)
        }
        phase = .idle
        guard let result else { return }

        if let learned, let bytes = result.replies["\(learned.header) \(learned.did)"] {
            showHistory(bytes, learned)
        }
        compareCandidates(result)
        message = nextStep
    }

    /// Each undecided candidate against its last reading: shifted after a regeneration -> it's the
    /// history; changed without one -> it isn't.
    private func compareCandidates(_ result: RefreshResult) {
        var changed = false
        for i in candidates.indices where candidates[i].verdict == nil {
            let candidate = candidates[i]
            guard let new = result.replies[candidate.id], new.count == candidate.bytes.count else { continue }
            var regenerations = Self.regenerations(since: candidate.regenCount, now: result.count)
            if regenerations == 0 {
                guard new != candidate.bytes else { continue }
                // Changed with the count unchanged: either the history written a moment after the count went
                // up (the snapshot was taken in between), or not the history at all.
                if Self.shift(old: candidate.bytes, new: new, entries: 1) != nil {
                    regenerations = 1
                } else {
                    candidates[i].verdict = false
                    changed = true
                    onLog?("DPF history: \(candidate.id) changed without a regeneration, ruled out")
                    continue
                }
            }
            guard let count = regenerations else { continue }
            if let shift = Self.shift(old: candidate.bytes, new: new, entries: count) {
                candidates[i].verdict = true
                candidates[i].entryWidth = shift.width
                candidates[i].newestFirst = shift.newestFirst
                candidates[i].bytes = new
                candidates[i].regenCount = result.count
                candidates[i].readAt = Date()
                onLog?("DPF history: \(candidate.id) shifted by \(count) after a regeneration: "
                       + "it's the regeneration history")
            } else {
                candidates[i].unshiftedChecks += 1     // maybe not written yet: the old reading stays
            }
            changed = true
        }
        guard changed else { return }
        candidates.sort { Self.score($0) > Self.score($1) }
        save()
        let confirmed = candidates.filter { $0.verdict == true }
        if learned?.confirmed != true, confirmed.count == 1, let found = confirmed.first {
            setLearned(Learned(header: found.header, did: found.did, entryWidth: found.entryWidth ?? 1,
                               newestFirst: found.newestFirst ?? true, confirmed: true), bytes: found.bytes)
            onLog?("DPF history: using \(found.id) (confirmed by a regeneration)")
        }
    }

    // MARK: Helpers

    private func setLearned(_ value: Learned, bytes: [UInt8]) {
        learned = value
        Self.store(value, key: Self.learnedKey)
        showHistory(bytes, value)
        message = nextStep
    }

    private func showHistory(_ bytes: [UInt8], _ learned: Learned) {
        historyRaw = bytes
        history = Self.decode(bytes, learned)
        historyRead = Date()
        UserDefaults.standard.set(Data(bytes), forKey: Self.rawKey)
        UserDefaults.standard.set(historyRead, forKey: Self.readKey)
    }

    private var nextStep: String {
        if let learned {
            return "Reading \(learned.header) 22\(learned.did)"
                + (learned.confirmed ? " (confirmed by a regeneration)" : " (picked by hand, not confirmed yet)")
        }
        if candidates.isEmpty {
            return "Step 1: car parked, ignition on — tap Scan (once, a few minutes)"
        }
        if candidates.contains(where: { $0.verdict == nil }) {
            return "Step 2: drive as usual. After the next regeneration the candidates are read again "
                + "(opening this screen also does it) and the one that moved along by one entry is used."
        }
        return "None of the candidates behaved like the history. Widen AppConfig.DPF.historyScanPlan and scan again."
    }

    /// Regenerations between two counts; nil if unknown or the count went down (reset).
    private static func regenerations(since old: Int?, now: Int?) -> Int? {
        guard let old, let now, now >= old else { return nil }
        return now - old
    }

    /// Whether `new` is `old` moved along by `entries` entries (1- or 2-byte entries, newest first or
    /// last); nil if not.
    static func shift(old: [UInt8], new: [UInt8], entries: Int) -> (width: Int, newestFirst: Bool)? {
        guard old.count == new.count, entries > 0 else { return nil }
        for width in [1, 2] {
            let n = entries * width
            guard old.count % width == 0, n < old.count, old.count - n >= 2 * width else { continue }
            let kept = old.count - n
            if Array(new[n...]) == Array(old[..<kept]) { return (width, true) }
            if Array(new[..<kept]) == Array(old[n...]) { return (width, false) }
        }
        return nil
    }

    /// The history in km, newest first: 1-byte entries × historyKmPerUnit, 2-byte entries as km.
    static func decode(_ bytes: [UInt8], _ learned: Learned) -> [Double] {
        let width = max(1, learned.entryWidth)
        var values: [Double] = []
        var i = 0
        while i + width <= bytes.count, values.count < Tuning.historyEntries {
            if width == 1 {
                values.append(Double(bytes[i]) * Tuning.historyKmPerUnit)
            } else {
                values.append(Double(Int(bytes[i]) * 256 + Int(bytes[i + 1])))
            }
            i += width
        }
        if learned.newestFirst { return values }
        return Array(values.reversed())
    }

    /// How much a candidate looks like the history: confirmed first; then exactly 10 bytes, most of them
    /// plausible distances (20–510 km); ruled out last.
    static func score(_ candidate: Candidate) -> Int {
        switch candidate.verdict {
        case true?: return 1000
        case false?: return -1000
        case nil: break
        }
        var score = candidate.bytes.count == Tuning.historyEntries ? 50 : 0
        score += candidate.bytes.prefix(Tuning.historyEntries).filter { (10...255).contains($0) }.count * 3
        return score - candidate.unshiftedChecks * 10
    }

    /// "8 of 10 bytes look like distances" etc., for the screen.
    static func plausibility(_ candidate: Candidate) -> String {
        let fitting = candidate.bytes.prefix(Tuning.historyEntries).filter { (10...255).contains($0) }.count
        return "\(candidate.bytes.count) bytes · \(fitting)/\(Tuning.historyEntries) look like distances"
    }

    private static func readCount(_ adapter: OBDAdapter) async -> Int? {
        let data = await adapter.readDID(MazdaDPF.Value.regenCount.did, from: MazdaDPF.header, complete: false,
                                         timeout: AppConfig.OBD.replyTimeout)
        return data.flatMap { MazdaDPF.regenCount($0) }
    }

    private func save() {
        Self.store(candidates, key: Self.candidatesKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func store<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
