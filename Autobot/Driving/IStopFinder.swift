// IStopFinder.swift
// Learns, on this car, the two things IStopController needs to switch i-stop off (nothing about
// i-stop is a standard OBD2 PID):
//
//   1. the i-stop STATE flag — which PCM value says i-stop is armed vs disabled. Found by comparing
//      snapshots of the PCM's DIDs with i-stop on and off (SignalDiff, like the M flag). Read-only
//      and reliable; this is what lets the auto-off confirm it worked.
//   2. an observed CAN frame that changes while the OFF button is held. The physical button is a
//      resistor ladder read by the instrument cluster. A changed frame is only a replay candidate;
//      rolling counters/checksums may make the captured bytes unusable (see README).
//
// Parked, engine running. Everything runs between two rounds of live data (OBDAdapter.runBetweenRounds),
// like the M, door and wiper finders.

import Combine
import Foundation

private typealias Tuning = AppConfig.IStop

final class IStopFinder: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case snapshot(label: String, done: Int, total: Int)
        case capturing(String)
    }

    @Published private(set) var phase: Phase = .idle

    // State (PCM DID diff)
    /// PCM DIDs that answer (from the scan, kept on the phone).
    @Published private(set) var supported: [String] = []
    @Published private(set) var onSnapshots = 0        // i-stop armed (available)
    @Published private(set) var offSnapshots = 0       // i-stop disabled (OFF switch active)
    @Published private(set) var stateCandidates: [SignalDiff.Candidate] = []
    @Published private(set) var learnedState: BitSignal?

    // Button (bus capture diff)
    @Published private(set) var idleCaptures = 0       // nothing pressed
    @Published private(set) var pressedCaptures = 0    // OFF button held
    @Published private(set) var frameCandidates: [FrameDiff.Candidate] = []
    @Published private(set) var learnedFrame: FrameSignal?

    /// What to do next / what happened.
    @Published private(set) var message = ""
    /// The raw bus captures as a shareable JSON file (for working the frame out by hand); nil until there are some.
    @Published private(set) var exportURL: URL?

    /// Results for the dashboard log.
    var onLog: ((String) -> Void)?

    var isBusy: Bool { phase != .idle }

    private let obd: OBDAdapter
    private let controller: IStopController
    private var onShots: [SignalDiff.Snapshot] = []
    private var offShots: [SignalDiff.Snapshot] = []
    private var idleBus: [FrameDiff.Capture] = []
    private var pressedBus: [FrameDiff.Capture] = []
    private var cancelRequested = false

    private static let supportedKey = "IStopFinder.supported"
    private static let planKey = "IStopFinder.scanPlan"
    private static let stateKey = "IStopFinder.state"
    private static let frameKey = "IStopFinder.frame"

    init(obd: OBDAdapter, controller: IStopController) {
        self.obd = obd
        self.controller = controller
        supported = Self.loadSupported()
        learnedState = Self.loadState()
        learnedFrame = Self.loadFrame()
        obd.iStopSignal = learnedState
        controller.buttonFrame = learnedFrame
        message = nextStep
    }

    // MARK: Actions

    func scan() { Task { await runScan() } }
    func snapshotState(off: Bool) { Task { await takeStateSnapshot(off: off) } }
    func captureBus(pressed: Bool) { Task { await takeCapture(pressed: pressed) } }
    func cancel() { cancelRequested = true }

    /// Forget the snapshots and captures taken so far (what's saved stays).
    func resetWork() {
        onShots = []; offShots = []
        idleBus = []; pressedBus = []
        onSnapshots = 0; offSnapshots = 0
        idleCaptures = 0; pressedCaptures = 0
        stateCandidates = []; frameCandidates = []
        exportURL = nil
        message = nextStep
    }

    /// Save confirmed state and frame candidates and hand them to the adapter / controller. The other
    /// learned value is left as saved when a candidate is not confirmed.
    func use() {
        var saved: [String] = []
        var skipped: [String] = []
        let stateConfirmed = onShots.count >= Tuning.snapshotsToConfirm
            && offShots.count >= Tuning.snapshotsToConfirm
            && SignalDiff.isUnambiguous(stateCandidates)
        if stateConfirmed, let best = stateCandidates.first {
            let signal = best.signal
            if let data = try? JSONEncoder().encode(signal) {
                UserDefaults.standard.set(data, forKey: Self.stateKey)
            }
            learnedState = signal
            obd.iStopSignal = signal
            saved.append("state " + signal.label(off: "on", on: "off"))
        } else if !stateCandidates.isEmpty {
            skipped.append("state needs two ON and two OFF snapshots with one clear candidate")
        }
        let frameConfirmed = idleBus.count >= 2 && pressedBus.count >= 2
            && FrameDiff.isUnambiguous(frameCandidates)
        if frameConfirmed, let best = frameCandidates.first {
            let frame = best.frame
            if let data = try? JSONEncoder().encode(frame) {
                UserDefaults.standard.set(data, forKey: Self.frameKey)
            }
            learnedFrame = frame
            controller.buttonFrame = frame
            saved.append("button " + frame.label())
        } else if !frameCandidates.isEmpty {
            skipped.append("button needs two released and two held captures with one clear candidate")
        }
        if !saved.isEmpty { message = "Saved. " + nextStep }
        else if !skipped.isEmpty { message = skipped.joined(separator: "; ") }
        else { message = "Nothing found yet to save." }
        if !saved.isEmpty { onLog?("i-stop finder: saved " + saved.joined(separator: " · ")) }
    }

    /// Back to nothing learned (auto-off can't press until it's learned again).
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
        UserDefaults.standard.removeObject(forKey: Self.frameKey)
        learnedState = nil
        learnedFrame = nil
        obd.iStopSignal = nil
        controller.buttonFrame = nil
        onLog?("i-stop finder: forgotten (state and button)")
        resetWork()
    }

    // MARK: Scan (PCM DIDs for the state flag)

    private func runScan() async {
        guard canStart() else { return }
        let plan = Tuning.stateScanPlan
        cancelRequested = false
        phase = .scanning(done: 0, total: 1)
        message = "Scanning the PCM… live data pauses for a minute or two"
        let found: [String]? = await obd.runBetweenRounds { [self] adapter in
            await adapter.scanDIDs(plan, timeout: Tuning.scanTimeout,
                                   progress: { done, total in phase = .scanning(done: done, total: total) },
                                   cancelled: { cancelRequested })
        }
        phase = .idle
        if cancelRequested { message = "Scan cancelled"; return }
        guard let found else {
            message = "Live data stopped during the scan — check the adapter and try again"
            return
        }
        supported = found
        UserDefaults.standard.set(found, forKey: Self.supportedKey)
        UserDefaults.standard.set(SignalDiff.planSignature(plan), forKey: Self.planKey)
        onLog?("i-stop finder: \(found.count) PCM DIDs answer")
        onShots = []; offShots = []; onSnapshots = 0; offSnapshots = 0; stateCandidates = []
        message = found.isEmpty ? "No DIDs answered — widen AppConfig.IStop.stateScanPlan" : nextStep
    }

    // MARK: State snapshots

    private func takeStateSnapshot(off: Bool) async {
        guard canStart() else { return }
        guard !supported.isEmpty else { message = "Scan the PCM first"; return }
        let label = off ? "i-stop OFF" : "i-stop ON"
        cancelRequested = false
        phase = .snapshot(label: label, done: 0, total: 1)
        let snapshot: SignalDiff.Snapshot? = await obd.runBetweenRounds { [self] adapter in
            await adapter.snapshotDIDs(supported, reads: Tuning.readsPerSnapshot,
                                       progress: { done, total in phase = .snapshot(label: label, done: done, total: total) },
                                       cancelled: { cancelRequested })
        }
        phase = .idle
        if cancelRequested { message = "Snapshot cancelled"; return }
        guard let snapshot, !snapshot.isEmpty else { message = "No answers — is live data running? Try again"; return }
        if off { offShots.append(snapshot); offSnapshots = offShots.count }
        else { onShots.append(snapshot); onSnapshots = onShots.count }
        onLog?("i-stop finder: \(label) snapshot #\(off ? offShots.count : onShots.count), \(snapshot.count) DIDs")
        compareState()
    }

    private func compareState() {
        guard !onShots.isEmpty, !offShots.isEmpty else { message = nextStep; return }
        // "on" in SignalDiff = the signal is set; we define set = i-stop disabled (OFF).
        stateCandidates = SignalDiff.candidates(on: offShots, off: onShots,
                                                ignored: Tuning.ignoredDIDs, preferredHeader: Tuning.stateHeader)
        guard let best = stateCandidates.first else {
            message = "Nothing in the PCM differs between i-stop on and off. Toggle the OFF button for real "
                + "between snapshots, or widen AppConfig.IStop.stateScanPlan."
            return
        }
        let enough = onShots.count >= Tuning.snapshotsToConfirm && offShots.count >= Tuning.snapshotsToConfirm
        if enough, SignalDiff.isUnambiguous(stateCandidates) {
            let signal = best.signal
            if let data = try? JSONEncoder().encode(signal) {
                UserDefaults.standard.set(data, forKey: Self.stateKey)
            }
            learnedState = signal
            obd.iStopSignal = signal
            message = "Found the i-stop state: \(signal.label(off: "on", on: "off")). " + nextStep
            onLog?("i-stop finder: state signal in use: \(signal.label(off: "on", on: "off"))")
        } else {
            message = "\(stateCandidates.count) state candidate(s), best: \(best.signal.label(off: "on", on: "off")). "
                + "One more i-stop ON and OFF snapshot to confirm."
        }
    }

    // MARK: Bus captures (the OFF button frame)

    private func takeCapture(pressed: Bool) async {
        guard canStart() else { return }
        let label = pressed ? "OFF held" : "nothing pressed"
        cancelRequested = false
        phase = .capturing(label)
        let captured: [(id: String, data: [UInt8])]? =
            await obd.runBetweenRounds { adapter in await adapter.captureAllFrames(within: Tuning.captureListen) } ?? nil
        phase = .idle
        if cancelRequested { message = "Capture cancelled"; return }
        guard let captured, !captured.isEmpty else {
            message = "Nothing captured on the bus — the adapter may not monitor all frames (see the log). "
                + "The state flag still works without this; the button can't be replayed."
            return
        }
        let group = grouped(captured)
        if pressed { pressedBus.append(group); pressedCaptures = pressedBus.count }
        else { idleBus.append(group); idleCaptures = idleBus.count }
        exportURL = writeExport()
        onLog?("i-stop finder: captured \(label): \(captured.count) frames, \(group.count) ids")
        compareFrame()
    }

    private func compareFrame() {
        guard !idleBus.isEmpty, !pressedBus.isEmpty else { message = nextStep; return }
        let ignored: Set<String> = [AppConfig.TurnSignals.frameID.uppercased()]
        frameCandidates = FrameDiff.candidates(idleCaptures: idleBus, pressedCaptures: pressedBus, ignoredIDs: ignored)
        guard let best = frameCandidates.first else {
            message = "No frame changed between released and held. Capture both again (hold the OFF button the "
                + "whole 2 s), or the button may not be on the bus — use FORScan coding instead (README)."
            return
        }
        let enough = idleBus.count >= 2 && pressedBus.count >= 2
        if enough, FrameDiff.isUnambiguous(frameCandidates) {
            let frame = best.frame
            if let data = try? JSONEncoder().encode(frame) {
                UserDefaults.standard.set(data, forKey: Self.frameKey)
            }
            learnedFrame = frame
            controller.buttonFrame = frame
            message = "Found the OFF button: \(frame.label()). " + nextStep
            onLog?("i-stop finder: button frame in use: \(frame.label())")
        } else {
            message = "\(frameCandidates.count) button candidate(s), best: \(best.frame.label()). "
                + "Capture released and held once more to confirm, then Use it."
        }
    }

    // MARK: Helpers

    private func grouped(_ frames: [(id: String, data: [UInt8])]) -> FrameDiff.Capture {
        var out: FrameDiff.Capture = [:]
        for frame in frames { out[frame.id, default: []].append(frame.data) }
        return out
    }

    private func canStart() -> Bool {
        guard !isBusy else { return false }
        guard obd.isReady else { message = "Connect the adapter and start the engine first"; return false }
        return true
    }

    private var nextStep: String {
        let state = learnedState != nil ? "state learned" : "state not learned"
        let button = learnedFrame != nil ? "button learned" : "button not learned"
        if learnedState != nil, learnedFrame != nil {
            return "Ready: \(state), \(button). Auto-off will run at the start of each drive."
        }
        if supported.isEmpty {
            return "Parked, engine running. State: Scan the PCM, then snapshot with i-stop ON and OFF. "
                + "Button: Capture the bus with nothing pressed and with the OFF button held. (\(state), \(button))"
        }
        if onShots.isEmpty || offShots.isEmpty {
            return "State: press the real OFF button so i-stop shows OFF → Snapshot i-stop OFF, press again so "
                + "it shows ON → Snapshot i-stop ON. Repeat once. (\(state), \(button))"
        }
        return "Button: Capture (nothing pressed), then hold the OFF button and Capture (OFF held). Twice each, "
            + "then Use it. (\(state), \(button))"
    }

    private func writeExport() -> URL? {
        guard !idleBus.isEmpty || !pressedBus.isEmpty else { return nil }
        func shots(_ captures: [FrameDiff.Capture], _ scene: String) -> [DoorExport.Shot] {
            captures.enumerated().map { (index, capture) -> DoorExport.Shot in
                let reads = capture.mapValues { frames in frames.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } }
                return DoorExport.Shot(scene: "\(scene) #\(index + 1)", reads: reads)
            }
        }
        let export = DoorExport(car: "Mazda CX-5 2.2D 2015",
                                takenAt: ISO8601DateFormatter().string(from: Date()),
                                shots: shots(idleBus, "i-stop released") + shots(pressedBus, "i-stop held"))
        guard let data = try? JSONEncoder.pretty.encode(export) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autobot-istop-scan.json")
        do { try data.write(to: url); return url } catch { return nil }
    }

    private static func loadState() -> BitSignal? {
        guard let data = UserDefaults.standard.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(BitSignal.self, from: data)
    }

    private static func loadFrame() -> FrameSignal? {
        guard let data = UserDefaults.standard.data(forKey: frameKey) else { return nil }
        return try? JSONDecoder().decode(FrameSignal.self, from: data)
    }

    private static func loadSupported() -> [String] {
        guard UserDefaults.standard.string(forKey: planKey) == SignalDiff.planSignature(Tuning.stateScanPlan) else {
            return []
        }
        return UserDefaults.standard.stringArray(forKey: supportedKey) ?? []
    }
}
