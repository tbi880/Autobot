// DoorFinder.swift
// Learns a door's switch by comparison, for doors the built-in door status doesn't cover. Normally
// every door comes straight from the body control module's door status (AppConfig.Doors.builtIn,
// 726 22C150, checked by OBDAdapter at each start); this is the fallback when the car doesn't
// answer that, or a door shows wrong:
//
//   1. Scan: which DIDs does the body control module (726) answer in AppConfig.Doors.scanPlan?
//      (about 2 minutes, done once and kept on the phone)
//   2. Snapshot "All closed": everything shut
//   3. For each opening in turn: open only that one, Snapshot "<it> open", close it again
//   4. One more "All closed" at the end
//
// For each opening, its snapshots are "on" and every other snapshot is "off" (it is closed in
// those, including the ones where another door is open). SignalDiff keeps the bits that are steady
// in both groups and differ between them: that door's switch. A bit every door sets (door-ajar lamp,
// interior light) is set in some "off" snapshots too, so it drops out. A door is saved once there
// are two snapshots with it closed, at least one of them with another door open; it then replaces
// the built-in signal for that door (OBDAdapter.learnedDoorSignals) and DoorMonitor follows.
//
// Scans and snapshots run between two rounds of live data (OBDAdapter.runBetweenRounds).

import Combine
import Foundation

private typealias Tuning = AppConfig.Doors

final class DoorFinder: ObservableObject {

    typealias Opening = DoorMonitor.Opening

    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case snapshot(label: String, done: Int, total: Int)
    }

    /// What a snapshot shows: everything closed, or exactly one opening open.
    enum Scene: Hashable {
        case allClosed
        case open(Opening)

        var label: String {
            switch self {
            case .allClosed: return "All closed"
            case .open(let opening): return "\(opening.rawValue) open"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// DIDs the body modules answer, "726 DA10" style (from the scan, kept on the phone).
    @Published private(set) var supported: [String] = []
    /// Snapshots taken so far, per scene.
    @Published private(set) var counts: [Scene: Int] = [:]
    /// The best candidate per opening from the snapshots so far.
    @Published private(set) var best: [Opening: SignalDiff.Candidate] = [:]
    /// The doors learned here (saved on the phone); each replaces the built-in signal for that door.
    @Published private(set) var learned: [Opening: BitSignal] = [:]
    /// What to do next / what happened, for the screen.
    @Published private(set) var message = ""

    /// Results for the dashboard log.
    var onLog: ((String) -> Void)?

    var isBusy: Bool { phase != .idle }

    private let obd: OBDAdapter
    private var snapshots: [(scene: Scene, snapshot: SignalDiff.Snapshot)] = []
    private var cancelRequested = false

    private static let supportedKey = "DoorFinder.supported"
    private static let planKey = "DoorFinder.scanPlan"
    private static let learnedKey = "DoorFinder.signals"

    init(obd: OBDAdapter) {
        self.obd = obd
        supported = Self.loadSupported()
        learned = Self.loadLearned()
        obd.learnedDoorSignals = learned
        message = nextStep
    }

    // MARK: Actions

    func scan() { Task { await runScan() } }
    func snapshot(_ scene: Scene) { Task { await takeSnapshot(scene) } }
    func cancel() { cancelRequested = true }

    /// Forget the snapshots taken so far (the scan result and the saved doors stay).
    func resetSnapshots() {
        snapshots = []
        counts = [:]
        best = [:]
        message = nextStep
    }

    /// Forget the learned doors: the built-in door status is used again where the car answers it.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.learnedKey)
        learned = [:]
        obd.learnedDoorSignals = [:]
        onLog?("Door finder: learned doors forgotten (built-in door status again)")
        resetSnapshots()
    }

    /// All raw snapshots as a shareable JSON file, for working out the door bits by hand when the
    /// automatic search can't. nil until there are snapshots.
    func exportFile() -> URL? {
        guard !snapshots.isEmpty else { return nil }
        let shots = snapshots.map { entry -> DoorExport.Shot in
            let reads = entry.snapshot.mapValues { perRead in
                perRead.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }
            }
            return DoorExport.Shot(scene: entry.scene.label, reads: reads)
        }
        let export = DoorExport(car: "Mazda CX-5 2.2D 2015", takenAt: ISO8601DateFormatter().string(from: Date()),
                                shots: shots)
        guard let data = try? JSONEncoder.pretty.encode(export) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autobot-door-scan.json")
        do { try data.write(to: url); return url } catch { return nil }
    }

    // MARK: Scan

    private func runScan() async {
        guard canStart() else { return }
        let plan = Tuning.scanPlan
        cancelRequested = false
        phase = .scanning(done: 0, total: 1)
        message = "Scanning the body control module… live data pauses for about 2 minutes"
        let found: [String]? = await obd.runBetweenRounds { [self] adapter in
            await adapter.scanDIDs(plan, timeout: Tuning.scanTimeout,
                                   progress: { done, total in phase = .scanning(done: done, total: total) },
                                   cancelled: { cancelRequested })
        }
        phase = .idle
        if cancelRequested {
            message = "Scan cancelled"
            return
        }
        guard let found else {
            message = "Live data stopped during the scan — check the adapter and try again"
            return
        }
        supported = found
        UserDefaults.standard.set(found, forKey: Self.supportedKey)
        UserDefaults.standard.set(SignalDiff.planSignature(plan), forKey: Self.planKey)
        onLog?("Door finder: \(found.count) DIDs answer: " + found.joined(separator: ", "))
        resetSnapshots()
        if found.isEmpty {
            message = "No DIDs answered in AppConfig.Doors.scanPlan. The adapter may not hear the 726 "
                + "replies (see the log for ATCRA), or the plan needs other ranges."
        }
    }

    // MARK: Snapshots

    private func takeSnapshot(_ scene: Scene) async {
        guard canStart() else { return }
        guard !supported.isEmpty else {
            message = "Scan first"
            return
        }
        let keys = supported
        let label = scene.label
        cancelRequested = false
        phase = .snapshot(label: label, done: 0, total: 1)
        let snapshot: SignalDiff.Snapshot? = await obd.runBetweenRounds { [self] adapter in
            await adapter.snapshotDIDs(keys, reads: Tuning.readsPerSnapshot,
                                       progress: { done, total in
                                           phase = .snapshot(label: label, done: done, total: total)
                                       },
                                       cancelled: { cancelRequested })
        }
        phase = .idle
        if cancelRequested {
            message = "Snapshot cancelled"
            return
        }
        guard let snapshot, !snapshot.isEmpty else {
            message = "No answers — is live data running? Try again"
            return
        }
        snapshots.append((scene, snapshot))
        counts[scene, default: 0] += 1
        onLog?("Door finder: snapshot \"\(label)\", \(snapshot.count) DIDs answered")
        solve()
    }

    /// Each opening against everything else; saves the doors with enough evidence.
    private func solve() {
        var found: [Opening: SignalDiff.Candidate] = [:]
        var changed = false
        for opening in Opening.allCases {
            let on = snapshots.filter { $0.scene == .open(opening) }.map(\.snapshot)
            let off = snapshots.filter { $0.scene != .open(opening) }.map(\.snapshot)
            guard !on.isEmpty, !off.isEmpty else { continue }
            let candidates = SignalDiff.candidates(on: on, off: off, ignored: Tuning.ignoredDIDs,
                                                   preferredHeader: Tuning.preferredHeader)
            if let top = candidates.first { found[opening] = top }
            let anotherDoorOpen = snapshots.contains { entry in
                if case .open(let other) = entry.scene { return other != opening }
                return false
            }
            guard off.count >= 2, anotherDoorOpen else { continue }      // not enough evidence yet
            if let top = candidates.first {
                // While two candidates tie, wait for more snapshots — unless every step is done,
                // then the best one is taken.
                guard SignalDiff.isUnambiguous(candidates) || allStepsDone else { continue }
                if learned[opening] != top.signal {
                    learned[opening] = top.signal
                    changed = true
                    onLog?("Door finder: \(opening.rawValue) = \(top.signal.label(off: "closed", on: "open"))")
                }
            } else if learned.removeValue(forKey: opening) != nil {
                changed = true
                onLog?("Door finder: \(opening.rawValue) not found (nothing specific to it)")
            }
        }
        best = found
        if changed {
            save()
            obd.learnedDoorSignals = learned
        }
        message = nextStep
    }

    // MARK: Helpers

    /// Every opening has a snapshot, and "All closed" was taken at least twice.
    private var allStepsDone: Bool {
        (counts[.allClosed] ?? 0) >= 2 && Opening.allCases.allSatisfy { (counts[.open($0)] ?? 0) > 0 }
    }

    private func canStart() -> Bool {
        guard !isBusy else { return false }
        guard obd.isReady else {
            message = "Connect the adapter and switch the ignition on first"
            return false
        }
        if let speed = obd.sample?.speed, speed >= 1 {
            message = "Stop the car first"
            return false
        }
        return true
    }

    /// The next thing to do, from what has been done so far.
    private var nextStep: String {
        if supported.isEmpty {
            return learned.isEmpty
                ? "Only needed if a door isn't shown right. Step 1: parked, ignition on, all doors "
                    + "closed — tap Scan (once, about 2 min)"
                : "\(learned.count) of \(Opening.allCases.count) openings learned"
        }
        if snapshots.isEmpty {
            return learned.isEmpty
                ? "Close everything — tap \"All closed\""
                : "\(learned.count) of \(Opening.allCases.count) openings learned. To learn again: "
                    + "close everything — tap \"All closed\""
        }
        if (counts[.allClosed] ?? 0) == 0 { return "Close everything — tap \"All closed\"" }
        if let next = Opening.allCases.first(where: { (counts[.open($0)] ?? 0) == 0 }) {
            return "Open only the \(next.rawValue) (everything else shut) — tap \"\(next.rawValue) open\", "
                + "then close it"
        }
        if (counts[.allClosed] ?? 0) < 2 { return "Close everything — tap \"All closed\" once more to finish" }
        let missing = Opening.allCases.filter { learned[$0] == nil }.map(\.rawValue)
        return missing.isEmpty
            ? "Done: all \(Opening.allCases.count) openings found and in use"
            : "Found \(learned.count) of \(Opening.allCases.count). Not found: "
                + missing.joined(separator: ", ") + " — try that one again, or widen the scan plan."
    }

    private func save() {
        let byName = Dictionary(uniqueKeysWithValues: learned.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(byName) {
            UserDefaults.standard.set(data, forKey: Self.learnedKey)
        }
    }

    private static func loadLearned() -> [Opening: BitSignal] {
        guard let data = UserDefaults.standard.data(forKey: learnedKey),
              let byName = try? JSONDecoder().decode([String: BitSignal].self, from: data) else { return [:] }
        var result: [Opening: BitSignal] = [:]
        for (name, signal) in byName {
            if let opening = Opening(rawValue: name) { result[opening] = signal }
        }
        return result
    }

    /// The scan result, if it was made with the current scan plan.
    private static func loadSupported() -> [String] {
        guard UserDefaults.standard.string(forKey: planKey) == SignalDiff.planSignature(Tuning.scanPlan) else {
            return []
        }
        return UserDefaults.standard.stringArray(forKey: supportedKey) ?? []
    }
}
