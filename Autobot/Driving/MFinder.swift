// MFinder.swift
// Finds the "lever in M" flag by comparison. On this car it found TCM 7E1 DID 1E03 byte 0 bit 0x10,
// which is now built in (AppConfig.Transmission.mFlag), so this is only needed again for another car
// or after a TCM software change. How it works:
//
//   1. Scan: which DIDs do the TCM (7E1) and the PCM (7E0) answer? (AppConfig.MFinder.scanPlan,
//      about 1–2 minutes, done once and kept on the phone)
//   2. Snapshot D: car stopped, foot on the brake, lever in D -> every supported DID is read
//   3. Snapshot M: lever in M, staying in M1 (the same gear as D at a stop) -> read again
//   4. SignalDiff lists the bits that are steady in each position but differ between them. After
//      two snapshots of each (D, M, D, M) the best candidate is saved and used instead of the
//      built-in flag, until "Forget".
//
// Scans and snapshots run between two rounds of live data (OBDAdapter.runBetweenRounds).

import Combine
import Foundation

private typealias Tuning = AppConfig.MFinder

final class MFinder: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case snapshot(position: String, done: Int, total: Int)
    }

    @Published private(set) var phase: Phase = .idle
    /// DIDs the car answers, "7E1 1E12" style (from the scan, kept on the phone).
    @Published private(set) var supported: [String] = []
    @Published private(set) var dSnapshots = 0
    @Published private(set) var mSnapshots = 0
    /// Possible M flags, best first.
    @Published private(set) var candidates: [SignalDiff.Candidate] = []
    /// A learned M flag that replaces the built-in one (saved on the phone); nil = built-in in use.
    @Published private(set) var learned: BitSignal?
    /// What to do next / what happened, for the screen.
    @Published private(set) var message = ""

    /// Results for the dashboard log.
    var onLog: ((String) -> Void)?

    var isBusy: Bool { phase != .idle }
    /// The M flag Power Mode uses now.
    var inUse: BitSignal { learned ?? AppConfig.Transmission.mFlag }

    private let obd: OBDAdapter
    private var d: [SignalDiff.Snapshot] = []
    private var m: [SignalDiff.Snapshot] = []
    private var cancelRequested = false

    private static let supportedKey = "MFinder.supported"
    private static let planKey = "MFinder.scanPlan"
    private static let learnedKey = "MFinder.mFlag"

    init(obd: OBDAdapter) {
        self.obd = obd
        supported = Self.loadSupported()
        learned = Self.loadLearned()
        obd.mFlag = learned ?? AppConfig.Transmission.mFlag
        message = nextStep
    }

    // MARK: Actions

    func scan() { Task { await runScan() } }
    func snapshotD() { Task { await takeSnapshot(inM: false) } }
    func snapshotM() { Task { await takeSnapshot(inM: true) } }
    func cancel() { cancelRequested = true }

    /// Forget the snapshots taken so far (the scan result stays).
    func resetSnapshots() {
        d = []
        m = []
        dSnapshots = 0
        mSnapshots = 0
        candidates = []
        message = nextStep
    }

    /// Back to the built-in M flag.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.learnedKey)
        learned = nil
        obd.mFlag = AppConfig.Transmission.mFlag
        onLog?("M finder: learned M flag forgotten, built-in one in use")
        resetSnapshots()
    }

    // MARK: Scan

    private func runScan() async {
        guard canStart() else { return }
        let plan = Tuning.scanPlan
        cancelRequested = false
        phase = .scanning(done: 0, total: 1)
        message = "Scanning… live data pauses for a minute or two"
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
        onLog?("M finder: \(found.count) DIDs answer: " + found.joined(separator: ", "))
        resetSnapshots()
        if found.isEmpty { message = "No DIDs answered in the scanned ranges" }
    }

    // MARK: Snapshots

    private func takeSnapshot(inM: Bool) async {
        guard canStart() else { return }
        guard !supported.isEmpty else {
            message = "Scan first"
            return
        }
        let position = inM ? "M" : "D"
        let keys = supported
        cancelRequested = false
        phase = .snapshot(position: position, done: 0, total: 1)
        let snapshot: SignalDiff.Snapshot? = await obd.runBetweenRounds { [self] adapter in
            await adapter.snapshotDIDs(keys, reads: Tuning.readsPerSnapshot,
                                       progress: { done, total in
                                           phase = .snapshot(position: position, done: done, total: total)
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
        if inM {
            m.append(snapshot)
            mSnapshots = m.count
        } else {
            d.append(snapshot)
            dSnapshots = d.count
        }
        onLog?("M finder: snapshot \(position) #\(inM ? m.count : d.count), \(snapshot.count) DIDs answered")
        compare()
    }

    /// Compares the D and M snapshots; once each position has enough, the best candidate is used.
    private func compare() {
        guard !d.isEmpty, !m.isEmpty else {
            message = nextStep
            return
        }
        candidates = SignalDiff.candidates(on: m, off: d, ignored: Tuning.ignoredDIDs,
                                           preferredHeader: MazdaTCM.header)
        guard let best = candidates.first else {
            message = "Nothing differs between D and M in the scanned DIDs. Make sure the lever really "
                + "moved to M (and stayed in M1), or widen AppConfig.MFinder.scanPlan."
            onLog?("M finder: no difference between D and M")
            return
        }
        onLog?("M finder: \(candidates.count) candidate(s): "
               + candidates.prefix(5).map { $0.signal.label(off: "D", on: "M") }.joined(separator: " | "))
        let enough = d.count >= Tuning.snapshotsToConfirm && m.count >= Tuning.snapshotsToConfirm
        let plenty = d.count > Tuning.snapshotsToConfirm && m.count > Tuning.snapshotsToConfirm
        if enough, SignalDiff.isUnambiguous(candidates) || plenty {
            let signal = best.signal
            if let data = try? JSONEncoder().encode(signal) {
                UserDefaults.standard.set(data, forKey: Self.learnedKey)
            }
            learned = signal
            obd.mFlag = signal
            message = "Found the M flag: \(signal.label(off: "D", on: "M")). Power Mode now follows M ↔ D."
            onLog?("M finder: M flag in use: \(signal.label(off: "D", on: "M"))")
        } else {
            message = "\(candidates.count) candidate(s), best: \(best.signal.label(off: "D", on: "M")). "
                + "Take one more D and M snapshot to confirm."
        }
    }

    // MARK: Helpers

    private func canStart() -> Bool {
        guard !isBusy else { return false }
        guard obd.isReady else {
            message = "Connect the adapter and start the engine first"
            return false
        }
        if let speed = obd.sample?.speed, speed >= 1 {
            message = "Stop the car first (foot on the brake)"
            return false
        }
        return true
    }

    /// The next thing to do, from what has been done so far.
    private var nextStep: String {
        if d.isEmpty, m.isEmpty {
            return "M flag in use: \(inUse.label(off: "D", on: "M"))" + (learned == nil ? " (built in)" : " (learned)")
        }
        if supported.isEmpty { return "Step 1: car stopped, engine running — tap Scan (once, 1–2 min)" }
        if d.count <= m.count { return "Lever in D, foot on the brake — tap Snapshot D" }
        return "Lever in M (stay in M1) — tap Snapshot M"
    }

    private static func loadLearned() -> BitSignal? {
        guard let data = UserDefaults.standard.data(forKey: learnedKey) else { return nil }
        return try? JSONDecoder().decode(BitSignal.self, from: data)
    }

    /// The scan result, if it was made with the current scan plan.
    private static func loadSupported() -> [String] {
        guard UserDefaults.standard.string(forKey: planKey) == SignalDiff.planSignature(Tuning.scanPlan) else {
            return []
        }
        return UserDefaults.standard.stringArray(forKey: supportedKey) ?? []
    }
}
