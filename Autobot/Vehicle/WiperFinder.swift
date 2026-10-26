// WiperFinder.swift
// Learns this car's wiper bits by comparison, in two places:
//
//   - the lever and the washer, in the lights frame (09A): about 2 s of the frame per lever position,
//     each compared with OFF (WiperSignal.learn);
//   - whether the wipers really wipe, in the front body control module (FBCM, 726), which drives the
//     wiper relays: its DIDs (scanned once, AppConfig.Rain.motorScanPlan) read with the wipers parked
//     (lever OFF, and AUTO on dry glass) and wiping (LO, HI, and the washer), compared like the door
//     finder's (SignalDiff). Rain mode needs this for AUTO: there the rain sensor decides when to wipe,
//     and the lever alone doesn't say. The washer is what tells the motor from the lever: the FBCM gets
//     the lever position too, but while washing the lever is OFF and the wipers still wipe.
//
// Parked, engine running: Scan once, then OFF → AUTO (dry glass) → LO → HI → Washer (lever OFF, pulled
// towards you and held) → OFF again. Each step takes the frame and the FBCM's DIDs; the washer step
// reads only the DIDs that may hold the motor bit, so it's quick to hold. "Use it" saves what was found
// on the phone, and rain mode follows it instead of the built-in guess (AppConfig.Rain.builtIn), until
// "Forget". Everything runs between two rounds of live data (OBDAdapter.runBetweenRounds), like the M and
// door finders.

import Combine
import Foundation

private typealias Tuning = AppConfig.Rain

final class WiperFinder: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case listening(String)
        case reading(label: String, done: Int, total: Int)
    }

    @Published private(set) var phase: Phase = .idle
    /// The FBCM has been scanned (with the current scan plan)…
    @Published private(set) var scanned = false
    /// …and these DIDs answered, "726 DA10" style (kept on the phone).
    @Published private(set) var motorDIDs: [String] = []
    /// Snapshots taken per position.
    @Published private(set) var counts: [WiperSignal.Position: Int] = [:]
    /// The lever and washer bits the snapshots so far show; nil until OFF and a wiping position differ.
    @Published private(set) var candidate: WiperSignal?
    /// The FBCM bit(s) that say "wiping" (one, or one for LO and one for HI), from the snapshots so far.
    @Published private(set) var motorCandidates: [BitSignal] = []
    /// What to look out for (missing steps, washer reads like wiping…).
    @Published private(set) var notes: [String] = []
    /// The learned lever bits (saved on the phone); nil = the built-in guess is in use.
    @Published private(set) var learned: WiperSignal?
    /// The learned wiper motor bits (saved on the phone); empty = not known, AUTO doesn't count.
    @Published private(set) var learnedMotor: [BitSignal] = []
    /// What to do next / what happened, for the screen.
    @Published private(set) var message = ""
    /// The raw snapshots as a JSON file to share (written after each one); nil until there are some.
    @Published private(set) var exportURL: URL?

    /// Results for the dashboard log.
    var onLog: ((String) -> Void)?

    var isBusy: Bool { phase != .idle }
    /// The lever bits rain mode uses now.
    var inUse: WiperSignal { learned ?? Tuning.builtIn }

    /// One step: the frames heard, and the FBCM's DIDs as read (empty when it wasn't read).
    private struct Shot {
        let position: WiperSignal.Position
        let frames: [[UInt8]]
        let motor: SignalDiff.Snapshot
    }

    private let obd: OBDAdapter
    private let rain: RainMode
    private var shots: [Shot] = []
    private var washerKeys: [String] = []          // the DIDs that may hold the motor bit: the washer reads them
    private var washerCheckPending = false         // …and hasn't yet
    private var motorAmbiguous = false             // more than one FBCM bit fits the motor so far
    private var cancelRequested = false

    private static let learnedKey = "WiperFinder.signal"
    private static let motorKey = "WiperFinder.motor"
    private static let motorDIDsKey = "WiperFinder.motorDIDs"
    private static let motorPlanKey = "WiperFinder.motorPlan"

    init(obd: OBDAdapter, rain: RainMode) {
        self.obd = obd
        self.rain = rain
        learned = Self.loadLearned()
        learnedMotor = Self.loadMotor()
        if let found = Self.loadMotorDIDs() {
            scanned = true
            motorDIDs = found
        }
        rain.signal = learned ?? Tuning.builtIn
        rain.motorSignals = learnedMotor
        message = nextStep
    }

    // MARK: Actions

    func scan() { Task { await runScan() } }
    func snapshot(_ position: WiperSignal.Position) { Task { await take(position) } }
    func cancel() { cancelRequested = true }

    /// Saves what was found and hands it to rain mode (lever bits and motor bits each only if found:
    /// the other keeps what was saved before).
    func use() {
        guard candidate != nil || !motorCandidates.isEmpty else { return }
        var saved: [String] = []
        if let candidate {
            if let data = try? JSONEncoder().encode(candidate) {
                UserDefaults.standard.set(data, forKey: Self.learnedKey)
            }
            learned = candidate
            rain.signal = candidate
            saved += candidate.descriptions
        }
        if !motorCandidates.isEmpty {
            if let data = try? JSONEncoder().encode(motorCandidates) {
                UserDefaults.standard.set(data, forKey: Self.motorKey)
            }
            learnedMotor = motorCandidates
            rain.motorSignals = motorCandidates
            saved += motorCandidates.map { "wiping: " + $0.label(off: "parked", on: "wiping") }
        }
        message = "Saved: rain mode follows these bits now."
        onLog?("Wiper finder: saved " + saved.joined(separator: " · "))
    }

    /// Back to the built-in lever guess, and no wiper motor bits (AUTO doesn't count any more).
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.learnedKey)
        UserDefaults.standard.removeObject(forKey: Self.motorKey)
        learned = nil
        learnedMotor = []
        rain.signal = Tuning.builtIn
        rain.motorSignals = []
        message = "Forgotten: back to the built-in guess, AUTO doesn't count."
        onLog?("Wiper finder: learned bits forgotten (built-in guess, AUTO doesn't count)")
    }

    /// Forget the snapshots taken so far (the scan result and what was saved stay).
    func resetSnapshots() {
        shots = []
        counts = [:]
        candidate = nil
        motorCandidates = []
        notes = []
        washerKeys = []
        washerCheckPending = false
        motorAmbiguous = false
        exportURL = nil
        message = nextStep
    }

    /// All raw snapshots (the frames and the FBCM's reads per step) as a shareable JSON file, for working
    /// the bits out by hand when the automatic search can't. Same layout as the door finder's export.
    /// nil if there are none or it can't be written.
    private func writeExport() -> URL? {
        guard !shots.isEmpty else { return nil }
        let frameKey = "frame " + AppConfig.TurnSignals.frameID
        let exported = shots.map { shot -> DoorExport.Shot in
            var reads = shot.motor.mapValues { perRead in perRead.map(Self.hex) }
            reads[frameKey] = shot.frames.map(Self.hex)
            return DoorExport.Shot(scene: "Wipers " + shot.position.label, reads: reads)
        }
        let export = DoorExport(car: "Mazda CX-5 2.2D 2015", takenAt: ISO8601DateFormatter().string(from: Date()),
                                shots: exported)
        guard let data = try? JSONEncoder.pretty.encode(export) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autobot-wiper-scan.json")
        do { try data.write(to: url); return url } catch { return nil }
    }

    // MARK: Scan

    /// Which of the FBCM's DIDs answer (AppConfig.Rain.motorScanPlan): done once, kept on the phone.
    private func runScan() async {
        guard canStart() else { return }
        let plan = Tuning.motorScanPlan
        cancelRequested = false
        phase = .scanning(done: 0, total: 1)
        message = "Scanning the front body control module… live data pauses for a few minutes"
        let found: [String]? = await obd.runBetweenRounds { [self] adapter in
            await adapter.scanDIDs(plan, timeout: Tuning.motorScanTimeout,
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
        let usable = found.filter { !Tuning.motorIgnoredDIDs.contains($0) }
        scanned = true
        motorDIDs = usable
        UserDefaults.standard.set(usable, forKey: Self.motorDIDsKey)
        UserDefaults.standard.set(SignalDiff.planSignature(plan), forKey: Self.motorPlanKey)
        onLog?("Wiper finder: \(found.count) FBCM DIDs answer: " + found.joined(separator: ", "))
        resetSnapshots()
        if usable.isEmpty {
            message = "No DIDs answered in AppConfig.Rain.motorScanPlan: the adapter may not hear the 726 "
                + "replies (see the log for ATCRA), or the plan needs other ranges. The lever can still be "
                + "learned, but AUTO won't count as rain."
        }
    }

    // MARK: Snapshots

    /// The frame with the lever in `position`, then the FBCM's DIDs (all of them; for the washer only
    /// the ones that may hold the motor bit).
    private func take(_ position: WiperSignal.Position) async {
        guard canStart() else { return }
        cancelRequested = false
        let label = position.label
        let id = AppConfig.TurnSignals.frameID
        let duration = Tuning.snapshotListen
        let reads = max(Tuning.motorReadsPerSnapshot, 1)
        let keys = position == .washer ? washerKeys : motorDIDs
        phase = .listening(label)
        let result = await obd.runBetweenRounds {
            [self] (adapter: OBDAdapter) -> (frames: [CANFrame]?, motor: SignalDiff.Snapshot) in
            let frames = await adapter.listenFrames(id: id, duration: duration)
            guard frames?.isEmpty == false, !keys.isEmpty, !cancelRequested else { return (frames, [:]) }
            phase = .reading(label: label, done: 0, total: keys.count * reads)
            let motor = await adapter.snapshotDIDs(keys, reads: reads,
                                                   progress: { done, total in
                                                       phase = .reading(label: label, done: done, total: total)
                                                   },
                                                   cancelled: { cancelRequested })
            return (frames, motor)
        }
        phase = .idle
        if cancelRequested {
            message = "Cancelled"
            return
        }
        guard let result, let frames = result.frames, let last = frames.last else {
            message = "Frame \(id) not heard: is live data running (engine on, adapter connected)?"
            return
        }
        if !keys.isEmpty, result.motor.isEmpty {
            message = "\(label): the front body control module didn't answer. Try again."
            return
        }
        shots.append(Shot(position: position, frames: frames.map(\.data), motor: result.motor))
        counts[position, default: 0] += 1
        solve()
        exportURL = writeExport()
        let read = result.motor.isEmpty ? "" : " · \(result.motor.count) FBCM DIDs"
        onLog?("Wiper finder: \(label) · \(id) = " + TurnSignals.hex(last.data) + read)
        message = "\(label): \(frames.count) frames, last " + TurnSignals.hex(last.data) + read + ". " + nextStep
    }

    /// The lever bits from the frames, the motor bits from the FBCM.
    private func solve() {
        var frames: [WiperSignal.Position: [[[UInt8]]]] = [:]
        var motor: [WiperSignal.Position: [SignalDiff.Snapshot]] = [:]
        for shot in shots {
            frames[shot.position, default: []].append(shot.frames)
            if !shot.motor.isEmpty { motor[shot.position, default: []].append(shot.motor) }
        }
        let indicators = AppConfig.TurnSignals.leftBits | AppConfig.TurnSignals.rightBits
        let lever = WiperSignal.learn(frames, ignored: [AppConfig.TurnSignals.lampByte: indicators])
        let wiping = solveMotor(motor)
        candidate = lever.signal
        motorCandidates = wiping.signals
        motorAmbiguous = wiping.ambiguous
        washerKeys = wiping.toCheck
        washerCheckPending = !wiping.toCheck.isEmpty && (motor[.washer] ?? []).isEmpty
        notes = lever.notes + wiping.notes
    }

    /// What the FBCM snapshots say about the wiper motor so far.
    private struct MotorResult {
        var signals: [BitSignal] = []
        var toCheck: [String] = []         // the DIDs the washer step reads
        var notes: [String] = []
        var ambiguous = false              // more than one bit fits: more OFF / LO snapshots sort it out
    }

    /// The FBCM bit(s) that say "wiping": steady while wiping (LO, HI, the washer) and while parked
    /// (OFF, AUTO on dry glass), and different between the two. The washer has the lever OFF, so a lever
    /// bit (the FBCM gets the lever position too) drops out there and only the motor's is left. One bit
    /// for every speed if there is one (a relay that's on at LO and HI), otherwise one for LO and one only
    /// HI has (separate LO and HI relays).
    private func solveMotor(_ motor: [WiperSignal.Position: [SignalDiff.Snapshot]]) -> MotorResult {
        guard scanned else { return MotorResult() }
        guard !motorDIDs.isEmpty else {
            return MotorResult(notes: ["Wiper motor: the scan found no FBCM DIDs, so AUTO can't count as rain."])
        }
        let parked = (motor[.off] ?? []) + (motor[.auto] ?? [])
        let low = motor[.low] ?? []
        let high = motor[.high] ?? []
        let washer = motor[.washer] ?? []
        guard !parked.isEmpty, !low.isEmpty || !high.isEmpty else { return MotorResult() }
        func candidates(_ running: [SignalDiff.Snapshot], _ notRunning: [SignalDiff.Snapshot]) -> [SignalDiff.Candidate] {
            SignalDiff.candidates(on: running, off: notRunning, ignored: Tuning.motorIgnoredDIDs,
                                  preferredHeader: Tuning.motorHeader)
        }
        // What could be the motor, before the washer has had its say.
        let maybe = candidates(low + high, parked) + candidates(low, parked) + candidates(high, parked)
        var result = MotorResult(toCheck: Array(Set(maybe.map(\.key))).sorted())
        guard !maybe.isEmpty else {
            result.notes = ["Wiper motor: nothing in the FBCM differs between parked and wiping. Widen "
                            + "AppConfig.Rain.motorScanPlan, or export the raw scan."]
            return result
        }
        guard !low.isEmpty else {
            result.notes = ["Wiper motor: take LO too."]
            return result
        }
        guard !washer.isEmpty else {
            result.notes = ["Wiper motor: \(result.toCheck.count) DIDs differ between parked and wiping. "
                            + "Take Washer: it tells the motor from the lever."]
            return result
        }
        let allSpeeds = candidates(low + high + washer, parked)
        if let top = allSpeeds.first {
            result.signals = [top.signal]
            result.ambiguous = !SignalDiff.isUnambiguous(allSpeeds)
            if high.isEmpty { result.notes.append("Wiper motor: take HI too, to check it's the same bit at HI.") }
        } else {
            let lowOnes = candidates(low + washer, parked)
            guard let lowTop = lowOnes.first else {
                result.notes = ["Wiper motor: no bit is on for LO and the washer alike (only lever bits "
                                + "differ?). Take Washer again while it wipes, or export the raw scan."]
                return result
            }
            result.signals = [lowTop.signal]
            result.ambiguous = !SignalDiff.isUnambiguous(lowOnes)
            if !high.isEmpty, let highTop = candidates(high, parked + low + washer).first {
                result.signals.append(highTop.signal)
            }
        }
        if result.ambiguous {
            result.notes.append("Wiper motor: more than one bit fits so far (the best is shown); OFF and LO once "
                                + "more drop the ones that only fit by chance.")
        }
        return result
    }

    // MARK: Helpers

    private func canStart() -> Bool {
        guard !isBusy else { return false }
        guard obd.isReady else {
            message = "Connect the adapter and start the engine first"
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
        func taken(_ position: WiperSignal.Position) -> Int { counts[position] ?? 0 }
        if !scanned {
            return "Parked, engine running. Step 1: Scan the front body control module (once, a few minutes), "
                + "so AUTO can tell when the wipers really wipe."
        }
        if taken(.off) == 0 { return "Lever OFF, wipers parked → tap OFF" }
        if taken(.auto) == 0 {
            return "Lever in AUTO on dry glass (if it wipes once, wait until it has parked) → tap AUTO / INT"
        }
        if taken(.low) == 0 { return "A quick spray, then the lever in LO, keep it wiping → tap LO" }
        if taken(.high) == 0 { return "Lever in HI, keep it wiping (spray again if the glass dries) → tap HI" }
        if taken(.washer) == 0 || washerCheckPending {
            return "Lever OFF, pull it towards you and keep holding until this is done → tap Washer"
        }
        if taken(.off) < 2 { return "Lever OFF, wait until the wipers have parked → tap OFF once more to finish" }
        if motorAmbiguous {
            return "Not sure yet which FBCM bit is the wiper motor: OFF (parked) and LO once more, then check again"
        }
        return "All steps done: check Found below, then Use it."
    }

    private nonisolated static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func loadLearned() -> WiperSignal? {
        guard let data = UserDefaults.standard.data(forKey: learnedKey) else { return nil }
        return try? JSONDecoder().decode(WiperSignal.self, from: data)
    }

    private static func loadMotor() -> [BitSignal] {
        guard let data = UserDefaults.standard.data(forKey: motorKey) else { return [] }
        return (try? JSONDecoder().decode([BitSignal].self, from: data)) ?? []
    }

    /// The scan result, if there is one made with the current scan plan.
    private static func loadMotorDIDs() -> [String]? {
        guard UserDefaults.standard.string(forKey: motorPlanKey) == SignalDiff.planSignature(Tuning.motorScanPlan) else {
            return nil
        }
        return UserDefaults.standard.stringArray(forKey: motorDIDsKey)
    }
}
