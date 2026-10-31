// DPFHistoryFinder.swift
// Finds where the PCM keeps the distances of its last 10 DPF regenerations ("DPF regeneration distance
// 01–10" in Mazda's dealer tool; the DID isn't published) and reads them. How:
//
//   1. Scan (car parked, engine running): every DID in AppConfig.DPF.historyScanPlan is asked, a chunk
//      at a time between two rounds of live data, so Power Mode etc. keep working, and a scan that
//      stops part-way (Pause, the car moving, the adapter gone, the app closed) carries on where it
//      stopped. Every DID that answers is read to the end twice; one that changes in between is a live
//      value. Two shapes of history are looked for among the steady ones:
//        - one DID holding all 10 entries (a reply of 10+ bytes), or
//        - a row of 10 consecutive DIDs with the same reply length (1–4 bytes), one entry each,
//      whose entries look like distances (AppConfig.DPF.historyPlausibleKm). Those are the candidates,
//      kept on the phone with the regeneration count at the time. DIDs the PCM refuses with anything
//      but "no such DID" (7F 22 31) are kept too: they exist but can't be read like this. The scan can
//      also run in the extended diagnostic session (10 03), where some DIDs only answer.
//   2. Later, after a regeneration (the count went up), the candidates are read again (when the DPF
//      screen opens, when the regeneration log records one, and at the end of a scan). The history
//      moves along by one entry per regeneration — a new distance in front, the oldest one gone — so
//      the candidate that shifted that way is it, and is used from then on. A candidate that changes
//      without a regeneration is ruled out.
//   "Use" picks one by hand before that, "Read by hand" asks DIDs typed in, and "Export raw scan"
//   shares every reply as JSON, for working it out by hand.
//
// Entries: 1 byte × AppConfig.DPF.historyKmPerUnit km (as the Torque preset for the SkyActiv-D shows
// them), 2 bytes in km, 3 or 4 bytes in 1/640 km like 220434.

import Combine
import Foundation

private typealias Tuning = AppConfig.DPF

final class DPFHistoryFinder: ObservableObject {

    struct Candidate: Codable, Identifiable, Equatable {
        var header: String
        /// The DID holding the history, or the first of `span` consecutive DIDs holding one entry each.
        var did: String
        /// nil: one DID; otherwise how many consecutive DIDs are read together (one entry each).
        var span: Int?
        /// Found in the extended diagnostic session (10 03): read there too.
        var extended: Bool?
        /// The reply (for a row: the DIDs' replies one after the other) when it was last compared.
        var bytes: [UInt8]
        var readAt: Date
        /// The regeneration count when `bytes` was read.
        var regenCount: Int?
        /// true: shifted by one entry after a regeneration (it's the history); false: changed without one.
        var verdict: Bool?
        /// Bytes per entry (known up front for a row) and, once the shift was seen, whether the newest
        /// entry is first.
        var entryWidth: Int?
        var newestFirst: Bool?
        /// Times it was re-read after a regeneration without having shifted.
        var unshiftedChecks = 0
        /// A row that is exactly 10 DIDs long (its neighbours answer differently).
        var exactRow: Bool?
        /// After a regeneration exactly one entry changed, in place: maybe a ring buffer. Check the
        /// values and "Use" it by hand.
        var oneEntryChanged: Bool?

        var id: String { DPFHistoryFinder.key(header, did, span) }
    }

    /// The history in use.
    struct Learned: Codable, Equatable {
        var header: String
        var did: String
        var span: Int?
        var extended: Bool?
        var entryWidth: Int
        var newestFirst: Bool
        /// true when found by the shift after a regeneration, false when picked by hand.
        var confirmed: Bool

        var id: String { DPFHistoryFinder.key(header, did, span) }
    }

    /// What the scan has found so far, kept so it carries on where it stopped.
    struct ScanState: Codable, Equatable {
        /// The plan scanned (DPFHistoryFinder.planText); a different plan starts again.
        var plan: String
        /// Asked in the extended diagnostic session (10 03) instead of the default one.
        var extended: Bool
        /// DIDs of the plan asked so far, in order, and how many there are.
        var done: Int
        var total: Int
        /// Every DID that answered ("7E0 0432"), read to the end.
        var answers: [String: [UInt8]]
        /// The second reading of the ones that changed in between: live values, not the history.
        var unsteady: [String: [UInt8]]
        /// DIDs refused with another code than 31 (no such DID): key -> negative response code.
        var refused: [String: UInt8]
        /// The regeneration count at the latest chunk.
        var regenCount: Int?
        /// Seconds per DID measured so far, for the time left.
        var secondsPerDID: Double?
        var finished: Date?

        var isComplete: Bool { done >= total }
    }

    enum Phase: Equatable {
        case idle
        /// `next`: the DID asked next ("7E0 0A40").
        case scanning(done: Int, total: Int, next: String)
        case reading
    }

    /// One DID read by hand: what came back.
    struct ManualRead: Identifiable, Equatable {
        var request: String
        var result: String
        var id: String { request }
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
    @Published private(set) var scanState: ScanState?
    /// Time left in the running scan (seconds), once measured.
    @Published private(set) var timeLeft: TimeInterval?
    /// The raw scan as a JSON file to share; nil before a scan.
    @Published private(set) var exportURL: URL?
    @Published private(set) var manualReads: [ManualRead] = []
    /// Scan (and read by hand) in the extended diagnostic session (10 03). Changing it starts the scan
    /// from the start again, keeping what was found.
    @Published var extendedSession = false {
        didSet { UserDefaults.standard.set(extendedSession, forKey: Self.extendedKey) }
    }

    var onLog: ((String) -> Void)?

    var isBusy: Bool { phase != .idle }

    private let obd: OBDAdapter
    private var cancelRequested = false

    private static let candidatesKey = "DPFHistoryFinder.candidates"
    private static let learnedKey = "DPFHistoryFinder.learned"
    private static let rawKey = "DPFHistoryFinder.raw"
    private static let readKey = "DPFHistoryFinder.read"
    private static let scanKey = "DPFHistoryFinder.scan"
    private static let extendedKey = "DPFHistoryFinder.extended"

    init(obd: OBDAdapter) {
        self.obd = obd
        extendedSession = UserDefaults.standard.bool(forKey: Self.extendedKey)
        candidates = Self.load([Candidate].self, key: Self.candidatesKey) ?? []
        learned = Self.load(Learned.self, key: Self.learnedKey)
        scanState = Self.load(ScanState.self, key: Self.scanKey)
        if let raw = UserDefaults.standard.data(forKey: Self.rawKey), let learned {
            historyRaw = [UInt8](raw)
            history = Self.decode([UInt8](raw), learned)
            historyRead = UserDefaults.standard.object(forKey: Self.readKey) as? Date
        }
        exportURL = writeExport()
        message = nextStep
    }

    // MARK: Actions

    /// Starts the scan, or carries on with one that stopped part-way.
    func scan() { Task { await runScan() } }
    /// Pauses the scan (what's done is kept).
    func cancel() { cancelRequested = true }

    /// Reads the history in use, and re-reads the candidates to see which shifted after a regeneration.
    /// Quietly does nothing without live data.
    func refresh() { Task { await runRefresh() } }

    /// Reads the DIDs typed in ("0435", "0435-043E", "0435 0438"; up to 64) from the PCM as they are.
    func readByHand(_ text: String) { Task { await runManualRead(text) } }

    /// Use this candidate as the history (before a regeneration has confirmed it).
    func use(_ candidate: Candidate) {
        setLearned(Learned(header: candidate.header, did: candidate.did, span: candidate.span,
                           extended: candidate.extended, entryWidth: Self.entryWidth(candidate),
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

    /// Forget the scan, its candidates and the history in use: start over.
    func resetCandidates() {
        guard !isBusy else { return }
        candidates = []
        save()
        scanState = nil
        UserDefaults.standard.removeObject(forKey: Self.scanKey)
        exportURL = nil
        forget()
    }

    /// Whether the next scan carries on from where one stopped (rather than starting at the beginning).
    var resumes: Bool {
        guard let state = scanState else { return false }
        return state.plan == Self.planText && state.total == Self.plan.count && !state.isComplete
            && state.done > 0 && state.extended == extendedSession
    }

    /// About how long the (rest of the) scan takes, minutes.
    var minutesLeft: Int {
        let perDID = scanState?.secondsPerDID ?? Tuning.historyScanSecondsPerDID
        let left = resumes ? (scanState.map { $0.total - $0.done } ?? Self.plan.count) : Self.plan.count
        return max(1, Int((Double(left) * perDID / 60).rounded(.up)))
    }

    // MARK: The plan

    private struct PlanKey {
        let header: String
        let did: String
        var id: String { "\(header) \(did)" }
    }

    /// Every DID of AppConfig.DPF.historyScanPlan, in order.
    private static let plan: [PlanKey] = Tuning.historyScanPlan.flatMap { entry -> [PlanKey] in
        entry.ranges.flatMap { range -> [PlanKey] in
            range.map { PlanKey(header: entry.header, did: String(format: "%04X", $0)) }
        }
    }

    /// The plan as text: "7E0 0300–04FF, 0000–02FF, …".
    static let planText: String = Tuning.historyScanPlan.map { entry -> String in
        let ranges = entry.ranges.map { String(format: "%04X–%04X", $0.lowerBound, $0.upperBound) }
        return entry.header + " " + ranges.joined(separator: ", ")
    }.joined(separator: "; ")

    static var planCount: Int { plan.count }

    // MARK: Scan

    /// One chunk of the scan, done between two rounds of live data.
    private struct ChunkResult {
        var asked = 0
        var answers: [String: [UInt8]] = [:]
        var unsteady: [String: [UInt8]] = [:]
        var refused: [String: UInt8] = [:]
        var regenCount: Int?
        /// Set when the PCM wouldn't go into the extended session: why.
        var sessionProblem: String?
    }

    private var isMoving: Bool { (obd.sample?.speed ?? 0) >= 1 }

    private func runScan() async {
        guard !isBusy else { return }
        guard obd.isReady else {
            message = "Connect the adapter and switch the ignition on first"
            return
        }
        guard !isMoving else {
            message = "Park the car first"
            return
        }
        let plan = Self.plan
        guard !plan.isEmpty else { return }
        let fresh = ScanState(plan: Self.planText, extended: extendedSession, done: 0, total: plan.count,
                              answers: [:], unsteady: [:], refused: [:])
        var state = fresh
        if let old = scanState, old.plan == Self.planText, old.total == plan.count {
            if old.extended != extendedSession {
                // The other session: from the start, keeping what answered and was refused before.
                state = old
                state.extended = extendedSession
                state.done = 0
                state.finished = nil
            } else if !old.isComplete {
                state = old                                // carry on where it stopped
            }
        }
        let extended = state.extended
        let firstDone = state.done
        let started = Date()
        cancelRequested = false
        var stopped: String?
        timeLeft = state.secondsPerDID.map { $0 * Double(plan.count - state.done) }
        phase = .scanning(done: state.done, total: plan.count, next: plan[state.done].id)
        message = "Scanning the PCM" + (extended ? " in the extended session" : "")
            + "… live data carries on between chunks"
        onLog?("DPF history: scan " + (firstDone > 0 ? "carries on from \(plan[firstDone].id)" : "starts")
               + (extended ? " (extended session)" : ""))

        while state.done < plan.count {
            if cancelRequested {
                stopped = "Scan paused at \(plan[state.done].id)"
                break
            }
            if isMoving {
                stopped = "Scan paused: the car is moving"
                break
            }
            let chunk = Array(plan[state.done..<min(state.done + max(Tuning.historyScanChunk, 1), plan.count)])
            let result: ChunkResult? = await obd.runBetweenRounds { [self] adapter in
                await Self.scanChunk(chunk, adapter: adapter, extended: extended, cancelled: { cancelRequested })
            }
            guard let result else {
                stopped = "Live data stopped at \(plan[state.done].id) — check the adapter"
                break
            }
            if let problem = result.sessionProblem {
                stopped = problem
                break
            }
            state.done += result.asked
            state.answers.merge(result.answers) { _, new in new }
            for (key, bytes) in result.unsteady { state.unsteady[key] = bytes }
            state.refused.merge(result.refused) { _, new in new }
            if let count = result.regenCount { state.regenCount = count }
            if state.done > firstDone {
                state.secondsPerDID = Date().timeIntervalSince(started) / Double(state.done - firstDone)
            }
            if state.isComplete { state.finished = Date() }
            timeLeft = state.secondsPerDID.map { $0 * Double(plan.count - state.done) }
            scanState = state
            saveScan()
            updateCandidates(from: state)
            if state.done < plan.count {
                phase = .scanning(done: state.done, total: plan.count, next: plan[state.done].id)
            }
            if result.asked < chunk.count, !state.isComplete {      // paused in the middle of the chunk
                stopped = "Scan paused at \(plan[state.done].id)"
                break
            }
        }
        if extended {           // back to the default session (the PCM would also drop back by itself)
            _ = await obd.runBetweenRounds { adapter in
                await adapter.diagnosticSession(0x01, header: MazdaDPF.header)
            }
        }
        phase = .idle
        timeLeft = nil

        let undecided = candidates.filter { $0.verdict == nil }.count
        let summary = "\(state.done) / \(state.total) asked, \(state.answers.count) answer "
            + "(\(state.unsteady.count) change by themselves), \(state.refused.count) refused, "
            + "\(undecided) candidates"
        onLog?("DPF history: " + (stopped ?? "scan done") + ": " + summary)
        if !state.refused.isEmpty {
            let codes = Dictionary(grouping: state.refused.values, by: { $0 }).mapValues(\.count)
            onLog?("DPF history: refused " + codes.keys.sorted()
                .map { String(format: "%02X", $0) + " ×\(codes[$0] ?? 0)" }.joined(separator: ", "))
        }
        if obd.isReady, !candidates.isEmpty {
            await runRefresh()         // rules out the ones that changed since they were scanned
        }
        message = (stopped.map { $0 + ". " } ?? "") + nextStep
    }

    /// Asks every DID of `chunk` (first frame only, fast), reads the ones that answer to the end twice,
    /// then the regeneration count.
    private static func scanChunk(_ chunk: [PlanKey], adapter: OBDAdapter, extended: Bool,
                                  cancelled: () -> Bool) async -> ChunkResult {
        var result = ChunkResult()
        if extended {
            for header in Set(chunk.map(\.header)).sorted() {
                switch await adapter.diagnosticSession(0x03, header: header) {
                case .data:
                    break
                case .refused(let code):
                    result.sessionProblem = String(format: "\(header) refused the extended session (7F 10 %02X, ", code)
                        + ELM327.negativeResponseName(code) + ")"
                    return result
                case .silent:
                    result.sessionProblem = "\(header) didn't answer the extended session request (1003)"
                    return result
                }
            }
        }
        var hits: [PlanKey] = []
        for key in chunk {
            if cancelled() { break }
            var reply = await adapter.probeDID(key.did, from: key.header, complete: false,
                                               timeout: Tuning.historyScanTimeout)
            if case .refused(let code) = reply, code == 0x78 || code == 0x21 {     // pending / busy: once more
                let again = await adapter.probeDID(key.did, from: key.header, complete: true,
                                                   timeout: AppConfig.OBD.probeTimeout)
                if case .silent = again {} else { reply = again }
            }
            switch reply {
            case .data(let bytes):
                if !bytes.isEmpty { hits.append(key) }
            case .refused(let code):
                if code != 0x31 { result.refused[key.id] = code }
            case .silent:
                break
            }
            result.asked += 1
        }
        for key in hits {
            if let bytes = await adapter.readDID(key.did, from: key.header, complete: true,
                                                 timeout: AppConfig.OBD.replyTimeout), !bytes.isEmpty {
                result.answers[key.id] = bytes
            }
        }
        for key in hits {
            guard let first = result.answers[key.id] else { continue }
            if let bytes = await adapter.readDID(key.did, from: key.header, complete: true,
                                                 timeout: AppConfig.OBD.replyTimeout),
               !bytes.isEmpty, bytes != first {
                result.unsteady[key.id] = bytes
            }
        }
        result.regenCount = await readCount(adapter)
        return result
    }

    /// Adds the candidates in what the scan found so far, keeps the ones found before (with what's
    /// known about them), drops the ones that turned out to change by themselves, best first.
    private func updateCandidates(from state: ScanState) {
        var merged = candidates
        for candidate in Self.findCandidates(in: state) where !merged.contains(where: { $0.id == candidate.id }) {
            merged.append(candidate)
        }
        merged.removeAll { candidate in
            candidate.verdict != true
                && Self.dids(candidate.did, candidate.span).contains { state.unsteady["\(candidate.header) \($0)"] != nil }
        }
        merged.sort { Self.score($0) > Self.score($1) }
        var undecided = 0
        candidates = merged.filter { candidate in
            guard candidate.verdict == nil else { return true }
            undecided += 1
            return undecided <= Tuning.historyMaxCandidates
        }
        save()
    }

    /// The candidates in a scan: steady DIDs of 10+ bytes, and rows of 10 consecutive steady DIDs of
    /// the same length, whose entries look like distances. The DPF values themselves never count.
    private static func findCandidates(in state: ScanState) -> [Candidate] {
        let known = Set(MazdaDPF.Value.allCases.map { "\(MazdaDPF.header) \($0.did)" })
        let entries = Tuning.historyEntries
        let now = Date()
        var found: [Candidate] = []
        var short: [String: [Int: [UInt8]]] = [:]         // header -> DID -> reply of 1–4 bytes
        for (key, bytes) in state.answers where state.unsteady[key] == nil && !known.contains(key) {
            let parts = key.split(separator: " ").map(String.init)
            guard parts.count == 2, let value = Int(parts[1], radix: 16) else { continue }
            if bytes.count >= entries {
                let candidate = Candidate(header: parts[0], did: parts[1], span: nil,
                                          extended: state.extended ? true : nil, bytes: bytes, readAt: now,
                                          regenCount: state.regenCount)
                if looksLikeHistory(candidate) { found.append(candidate) }
            } else if (1...4).contains(bytes.count) {
                short[parts[0], default: [:]][value] = bytes
            }
        }
        for (header, replies) in short {
            let sorted = replies.keys.sorted()
            var i = 0
            while i < sorted.count {
                let width = replies[sorted[i]]?.count ?? 0
                var j = i
                while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1, replies[sorted[j + 1]]?.count == width {
                    j += 1
                }
                let row = Array(sorted[i...j])
                if row.count >= entries {
                    for start in 0...(row.count - entries) {
                        let members = row[start..<(start + entries)]
                        let bytes = members.flatMap { replies[$0] ?? [] }
                        var candidate = Candidate(header: header, did: String(format: "%04X", row[start]),
                                                  span: entries, extended: state.extended ? true : nil,
                                                  bytes: bytes, readAt: now, regenCount: state.regenCount)
                        candidate.entryWidth = width
                        candidate.exactRow = row.count == entries ? true : nil
                        if looksLikeHistory(candidate) { found.append(candidate) }
                    }
                }
                i = j + 1
            }
        }
        return found
    }

    // MARK: Refresh

    /// One DID to read, and whether to wait for a reply of several frames.
    private struct ReadKey {
        let header: String
        let did: String
        let complete: Bool
        var id: String { "\(header) \(did)" }
    }

    private struct ReadResult {
        var replies: [String: [UInt8]] = [:]
        var count: Int?
    }

    private func runRefresh() async {
        guard !isBusy, obd.isReady else { return }
        var targets: [(header: String, did: String, span: Int?, extended: Bool)] = []
        if let learned {
            targets.append((learned.header, learned.did, learned.span, learned.extended == true))
        }
        if learned?.confirmed != true {
            for candidate in candidates where candidate.verdict == nil && candidate.id != learned?.id {
                targets.append((candidate.header, candidate.did, candidate.span, candidate.extended == true))
            }
        }
        guard !targets.isEmpty else { return }
        var reads: [ReadKey] = []
        for target in targets {
            for did in Self.dids(target.did, target.span) {
                let key = ReadKey(header: target.header, did: did, complete: target.span == nil)
                if !reads.contains(where: { $0.id == key.id }) { reads.append(key) }
            }
        }
        phase = .reading
        let result = await readAll(reads, extended: targets.contains { $0.extended })
        phase = .idle
        guard let result else { return }

        var replies: [String: [UInt8]] = [:]
        for target in targets {
            let parts = Self.dids(target.did, target.span).compactMap { result.replies["\(target.header) \($0)"] }
            guard parts.count == Self.dids(target.did, target.span).count else { continue }
            replies[Self.key(target.header, target.did, target.span)] = parts.flatMap { $0 }
        }
        if let learned, let bytes = replies[learned.id] {
            showHistory(bytes, learned)
        }
        compareCandidates(replies, regenCount: result.count)
        message = nextStep
    }

    /// Reads `keys` a chunk at a time between rounds of live data (in the extended session if asked),
    /// then the regeneration count. nil if live data stopped.
    private func readAll(_ keys: [ReadKey], extended: Bool) async -> ReadResult? {
        var total = ReadResult()
        var start = 0
        let size = max(Tuning.historyScanChunk / 2, 1)
        while start < keys.count {
            let part = Array(keys[start..<min(start + size, keys.count)])
            let isLast = start + part.count >= keys.count
            let got: ReadResult? = await obd.runBetweenRounds { adapter in
                if extended {
                    for header in Set(part.map(\.header)).sorted() {
                        _ = await adapter.diagnosticSession(0x03, header: header)
                    }
                }
                var result = ReadResult()
                for key in part {
                    if let bytes = await adapter.readDID(key.did, from: key.header, complete: key.complete,
                                                         timeout: AppConfig.OBD.replyTimeout) {
                        result.replies[key.id] = bytes
                    }
                }
                if isLast {
                    result.count = await Self.readCount(adapter)
                    if extended { _ = await adapter.diagnosticSession(0x01, header: MazdaDPF.header) }
                }
                return result
            }
            guard let got else { return nil }
            total.replies.merge(got.replies) { _, new in new }
            if isLast { total.count = got.count }
            start += part.count
        }
        return total
    }

    /// Each undecided candidate against its last reading: shifted after a regeneration -> it's the
    /// history; changed without one -> it isn't.
    private func compareCandidates(_ replies: [String: [UInt8]], regenCount: Int?) {
        var changed = false
        for i in candidates.indices where candidates[i].verdict == nil {
            let candidate = candidates[i]
            guard let new = replies[candidate.id], new.count == candidate.bytes.count else { continue }
            let widths = Self.shiftWidths(candidate)
            var regenerations = Self.regenerations(since: candidate.regenCount, now: regenCount)
            if regenerations == 0 {
                guard new != candidate.bytes else { continue }
                // Changed with the count unchanged: either the history written a moment after the count went
                // up (the snapshot was taken in between), or not the history at all.
                if Self.shift(old: candidate.bytes, new: new, entries: 1, widths: widths) != nil {
                    regenerations = 1
                } else {
                    candidates[i].verdict = false
                    changed = true
                    onLog?("DPF history: \(candidate.id) changed without a regeneration, ruled out")
                    continue
                }
            }
            guard let regens = regenerations else { continue }
            if let shift = Self.shift(old: candidate.bytes, new: new, entries: regens, widths: widths) {
                candidates[i].verdict = true
                candidates[i].entryWidth = shift.width
                candidates[i].newestFirst = shift.newestFirst
                candidates[i].bytes = new
                candidates[i].regenCount = regenCount
                candidates[i].readAt = Date()
                onLog?("DPF history: \(candidate.id) shifted by \(regens) after a regeneration: "
                       + "it's the regeneration history")
            } else {
                candidates[i].unshiftedChecks += 1     // maybe not written yet: the old reading stays
                if regens == 1, candidate.oneEntryChanged != true,
                   Self.changedEntries(old: candidate.bytes, new: new, width: Self.entryWidth(candidate)) == 1 {
                    candidates[i].oneEntryChanged = true
                    onLog?("DPF history: \(candidate.id): one entry changed in place after a regeneration "
                           + "(a ring buffer?) — check it and use it by hand")
                }
            }
            changed = true
        }
        guard changed else { return }
        candidates.sort { Self.score($0) > Self.score($1) }
        save()
        let confirmed = candidates.filter { $0.verdict == true }
        if learned?.confirmed != true, confirmed.count == 1, let found = confirmed.first {
            setLearned(Learned(header: found.header, did: found.did, span: found.span, extended: found.extended,
                               entryWidth: Self.entryWidth(found), newestFirst: found.newestFirst ?? true,
                               confirmed: true), bytes: found.bytes)
            onLog?("DPF history: using \(found.id) (confirmed by a regeneration)")
        }
    }

    // MARK: Read by hand

    private func runManualRead(_ text: String) async {
        guard !isBusy else { return }
        guard obd.isReady else {
            message = "Connect the adapter and switch the ignition on first"
            return
        }
        guard let dids = Self.parseDIDs(text) else {
            message = "Type a DID like 0435, a range like 0435-043E, or several: 0435 0438 (up to 64)"
            return
        }
        let extended = extendedSession
        let header = MazdaDPF.header
        phase = .reading
        let reads: [ManualRead]? = await obd.runBetweenRounds { adapter in
            var out: [ManualRead] = []
            if extended {
                let reply = await adapter.diagnosticSession(0x03, header: header)
                out.append(ManualRead(request: "\(header) 1003", result: Self.describe(reply, service: 0x10)))
            }
            for did in dids {
                let reply = await adapter.probeDID(did, from: header, complete: true,
                                                   timeout: AppConfig.OBD.replyTimeout)
                out.append(ManualRead(request: "\(header) 22\(did)", result: Self.describe(reply, service: 0x22)))
            }
            if extended { _ = await adapter.diagnosticSession(0x01, header: header) }
            return out
        }
        phase = .idle
        guard let reads else {
            message = "Live data stopped — check the adapter and try again"
            return
        }
        manualReads = reads
        for read in reads { onLog?("DPF history: \(read.request) -> \(read.result)") }
        message = nextStep
    }

    /// "0435", "220435", "0435-043E", "0435–043E", "0435 0438, 043A" -> the DIDs; nil if unreadable or
    /// more than 64.
    static func parseDIDs(_ text: String) -> [String]? {
        func value(_ token: Substring) -> Int? {
            var digits = String(token)
            if digits.count == 6, digits.hasPrefix("22") { digits.removeFirst(2) }
            guard digits.count == 4 else { return nil }
            return Int(digits, radix: 16)
        }
        var values: [Int] = []
        let normalized = text.uppercased().replacingOccurrences(of: "–", with: "-")
        for part in normalized.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let ends = part.split(separator: "-")
            guard (1...2).contains(ends.count), let low = value(ends[0]), let high = value(ends[ends.count - 1]),
                  low <= high, high - low < 64 else { return nil }
            for did in low...high where !values.contains(did) { values.append(did) }
            if values.count > 64 { return nil }
        }
        return values.isEmpty ? nil : values.map { String(format: "%04X", $0) }
    }

    static func describe(_ reply: OBDAdapter.UDSReply, service: UInt8) -> String {
        switch reply {
        case .data(let bytes):
            return bytes.isEmpty ? "answered, no data" : hex(bytes) + "  (\(bytes.count) B)"
        case .refused(let code):
            return String(format: "refused: 7F %02X %02X ", service, code) + ELM327.negativeResponseName(code)
        case .silent:
            return "no reply"
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
            return "Reading " + Self.title(learned.header, learned.did, learned.span)
                + (learned.confirmed ? " (confirmed by a regeneration)" : " (picked by hand, not confirmed yet)")
        }
        if resumes, let state = scanState {
            return "Scan stopped at \(state.done) / \(state.total): tap Scan to carry on (about \(minutesLeft) min)"
        }
        if candidates.contains(where: { $0.verdict == nil }) {
            return "Step 2: drive as usual. After the next regeneration the candidates are read again "
                + "(opening this screen also does it) and the one that moved along by one entry is used."
        }
        if let state = scanState, state.isComplete {
            let session = state.extended ? "the extended session" : "the default session"
            return "Scan done in \(session): \(state.answers.count) DIDs answer, none looks like 10 distances"
                + (candidates.isEmpty ? "" : " that behave like the history")
                + (state.extended ? "." : ". Next: switch on the extended session and scan again.")
                + " Export the raw scan to look through it by hand."
        }
        if !candidates.isEmpty {
            return "None of the candidates behaved like the history. Try the extended session, or widen "
                + "AppConfig.DPF.historyScanPlan, and scan again."
        }
        return "Step 1: car parked, engine running — tap Scan (about \(minutesLeft) min, can be done in parts)"
    }

    /// Regenerations between two counts; nil if unknown or the count went down (reset).
    private static func regenerations(since old: Int?, now: Int?) -> Int? {
        guard let old, let now, now >= old else { return nil }
        return now - old
    }

    /// Whether `new` is `old` moved along by `entries` entries (of one of `widths` bytes, newest first or
    /// last); nil if not, or if nothing changed.
    static func shift(old: [UInt8], new: [UInt8], entries: Int, widths: [Int] = [1, 2, 3, 4])
        -> (width: Int, newestFirst: Bool)? {
        guard old.count == new.count, entries > 0, old != new else { return nil }
        for width in widths where width > 0 {
            let n = entries * width
            guard old.count % width == 0, n < old.count, old.count - n >= 2 * width else { continue }
            let kept = old.count - n
            if Array(new[n...]) == Array(old[..<kept]) { return (width, true) }
            if Array(new[..<kept]) == Array(old[n...]) { return (width, false) }
        }
        return nil
    }

    /// The widths a candidate's shift is looked for with: a row's own, any for one DID.
    private static func shiftWidths(_ candidate: Candidate) -> [Int] {
        if candidate.span != nil, let width = candidate.entryWidth { return [width] }
        return [1, 2, 3, 4]
    }

    /// How many entries of `width` bytes differ between two readings.
    private static func changedEntries(old: [UInt8], new: [UInt8], width: Int) -> Int {
        let w = max(width, 1)
        guard old.count == new.count else { return 0 }
        return stride(from: 0, to: old.count - w + 1, by: w).filter { old[$0..<($0 + w)] != new[$0..<($0 + w)] }.count
    }

    /// The first 10 entries in km, as they are stored: 1 byte × historyKmPerUnit, 2 bytes as km, 3 or 4
    /// bytes (the low 3) / 640 like 220434.
    static func decodeEntries(_ bytes: [UInt8], width: Int) -> [Double] {
        let w = min(max(width, 1), 4)
        var values: [Double] = []
        var i = 0
        while i + w <= bytes.count, values.count < Tuning.historyEntries {
            let raw = bytes[i..<(i + w)].reduce(0) { $0 << 8 | Int($1) }
            switch w {
            case 1: values.append(Double(raw) * Tuning.historyKmPerUnit)
            case 2: values.append(Double(raw))
            default: values.append(Double(raw & 0xFF_FFFF) / 640)
            }
            i += w
        }
        return values
    }

    /// The history in km, newest first.
    static func decode(_ bytes: [UInt8], _ learned: Learned) -> [Double] {
        let values = decodeEntries(bytes, width: learned.entryWidth)
        return learned.newestFirst ? values : Array(values.reversed())
    }

    /// Bytes per entry: a row's own or the one seen in the shift; otherwise the width whose entries look
    /// most like distances.
    static func entryWidth(_ candidate: Candidate) -> Int {
        candidate.entryWidth ?? bestWidth(candidate.bytes)
    }

    private static func bestWidth(_ bytes: [UInt8]) -> Int {
        var best = (width: 1, fitting: -1)
        for width in 1...4 where bytes.count >= Tuning.historyEntries * width {
            let fitting = decodeEntries(bytes, width: width).filter { Tuning.historyPlausibleKm.contains($0) }.count
            if fitting > best.fitting { best = (width, fitting) }
        }
        return best.width
    }

    private static func entries(_ candidate: Candidate) -> [Double] {
        decodeEntries(candidate.bytes, width: entryWidth(candidate))
    }

    /// At least historyMinPlausible of 10 entries look like distances, and they're not all alike.
    private static func looksLikeHistory(_ candidate: Candidate) -> Bool {
        let km = entries(candidate)
        guard km.count == Tuning.historyEntries else { return false }
        return km.filter { Tuning.historyPlausibleKm.contains($0) }.count >= Tuning.historyMinPlausible
            && Set(km).count >= 3
    }

    /// How much a candidate looks like the history: confirmed first; then the ones whose 10 entries are
    /// plausible, varied distances and nothing else; ruled out last.
    static func score(_ candidate: Candidate) -> Int {
        switch candidate.verdict {
        case true?: return 1000
        case false?: return -1000
        case nil: break
        }
        let km = entries(candidate)
        var score = km.filter { Tuning.historyPlausibleKm.contains($0) }.count * 3
        if candidate.bytes.count == Tuning.historyEntries * entryWidth(candidate) { score += 20 }
        if candidate.exactRow == true { score += 15 }
        score += min(Set(km).count, 10)
        if candidate.oneEntryChanged == true { score += 100 }
        return score - candidate.unshiftedChecks * 10
    }

    /// "10 DIDs × 1 B · 8/10 look like distances" etc., for the screen.
    static func plausibility(_ candidate: Candidate) -> String {
        let km = entries(candidate)
        let fitting = km.filter { Tuning.historyPlausibleKm.contains($0) }.count
        let shape = candidate.span.map { "\($0) DIDs × \(entryWidth(candidate)) B" }
            ?? "\(candidate.bytes.count) bytes, \(entryWidth(candidate)) B per entry?"
        return shape + " · \(fitting)/\(Tuning.historyEntries) look like distances"
            + (candidate.extended == true ? " · extended session" : "")
    }

    /// The entries as km, with how they were scaled: "×2 km: 312 288 …".
    static func kmPreview(_ candidate: Candidate) -> String {
        let width = entryWidth(candidate)
        let scale = width == 1 ? "×\(Int(Tuning.historyKmPerUnit)) km" : width == 2 ? "km" : "/640 km"
        return scale + ": " + entries(candidate).map { String(format: "%.0f", $0) }.joined(separator: " ")
    }

    /// The key a candidate is stored and compared under: "7E0 0435" or "7E0 0435+10".
    static func key(_ header: String, _ did: String, _ span: Int?) -> String {
        guard let span else { return "\(header) \(did)" }
        return "\(header) \(did)+\(span)"
    }

    /// For the screen: "7E0 220435" or "7E0 220435…043E (10 DIDs)".
    static func title(_ header: String, _ did: String, _ span: Int?) -> String {
        let all = dids(did, span)
        guard all.count > 1, let last = all.last else { return "\(header) 22\(did)" }
        return "\(header) 22\(did)…\(last) (\(all.count) DIDs)"
    }

    /// The DIDs a candidate is read from: `did`, or `span` consecutive ones from it.
    static func dids(_ did: String, _ span: Int?) -> [String] {
        guard let span, span > 1, let first = Int(did, radix: 16) else { return [did] }
        return (0..<span).map { String(format: "%04X", first + $0) }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func readCount(_ adapter: OBDAdapter) async -> Int? {
        let data = await adapter.readDID(MazdaDPF.Value.regenCount.did, from: MazdaDPF.header, complete: false,
                                         timeout: AppConfig.OBD.replyTimeout)
        return data.flatMap { MazdaDPF.regenCount($0) }
    }

    private func save() {
        Self.store(candidates, key: Self.candidatesKey)
    }

    private func saveScan() {
        if let scanState { Self.store(scanState, key: Self.scanKey) }
        exportURL = writeExport()
    }

    /// The scan so far as a shareable JSON file: every reply, the refusals and the candidates.
    private func writeExport() -> URL? {
        guard let state = scanState else { return nil }
        let answers = state.answers.keys.sorted().map { key in
            DPFScanExport.Answer(did: key, reply: Self.hex(state.answers[key] ?? []),
                                 secondRead: state.unsteady[key].map { Self.hex($0) })
        }
        let refused = state.refused.keys.sorted().map { key in
            DPFScanExport.Refusal(did: key, reply: String(format: "7F 22 %02X ", state.refused[key] ?? 0)
                                  + ELM327.negativeResponseName(state.refused[key] ?? 0))
        }
        let candidateLines = self.candidates.map { candidate -> String in
            let verdict: String
            switch candidate.verdict {
            case true?: verdict = "confirmed"
            case false?: verdict = "ruled out"
            case nil: verdict = "undecided"
            }
            let title = Self.title(candidate.header, candidate.did, candidate.span)
            return "\(title) [\(verdict)] \(Self.plausibility(candidate)): \(Self.hex(candidate.bytes))"
        }
        let export = DPFScanExport(car: "Mazda CX-5 2.2D 2015",
                                   takenAt: ISO8601DateFormatter().string(from: Date()),
                                   session: state.extended ? "extended (10 03)" : "default",
                                   plan: state.plan, asked: "\(state.done) / \(state.total)",
                                   regenCount: state.regenCount, answers: answers, refused: refused,
                                   candidates: candidateLines)
        guard let data = try? JSONEncoder.pretty.encode(export) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autobot-dpf-history-scan.json")
        do { try data.write(to: url); return url } catch { return nil }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func store<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// The regeneration history scan as JSON (DPFHistoryFinder's "Export raw scan").
nonisolated struct DPFScanExport: Codable {
    struct Answer: Codable {
        /// "7E0 0432"
        let did: String
        /// "00 2F"
        let reply: String
        /// The second reading, when it differed (a live value).
        let secondRead: String?
    }
    struct Refusal: Codable {
        let did: String
        /// "7F 22 33 security access denied"
        let reply: String
    }
    let car: String
    let takenAt: String
    let session: String
    let plan: String
    let asked: String
    let regenCount: Int?
    let answers: [Answer]
    let refused: [Refusal]
    let candidates: [String]
}
