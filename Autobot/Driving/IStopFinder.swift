// IStopFinder.swift
// Learns, on this car, the two things IStopController needs to switch i-stop off (nothing about
// i-stop is a standard OBD2 PID):
//
//   1. the i-stop STATE flag — which PCM value says i-stop is armed vs disabled. Found by comparing
//      snapshots of the PCM's DIDs with i-stop on and off (SignalDiff, like the M flag). Read-only
//      and reliable; this is what lets the auto-off confirm it worked.
//   2. an observed CAN frame that changes while the OFF button is held. The physical button is a
//      resistor ladder read by the instrument cluster, which reports it to the PCM on HS-CAN. A changed
//      frame is only a replay candidate; rolling counters/checksums may make the captured bytes
//      unusable (see README).
//      One capture of the whole bus overflows the adapter (well over 1000 frames a second), so the bus is
//      first MAPPED in small blocks of CAN ids (census: a block that overflows is split in two), then
//      SWEPT one block per press: released → held → released again, with spoken "Hold" / "Release"
//      prompts and the state flag read before and after to prove the press registered. A bit that is set
//      only while held is the button (momentary); one that stays after release is the i-stop status echo
//      (latched).
//   3. which modules this adapter reaches (one harmless tester present each), and — if the start stop
//      unit answers — its as-built block, read-only: that's where the i-stop default lives.
//
// Parked, engine running. Everything runs between two rounds of live data (OBDAdapter.runBetweenRounds),
// like the M and door finders.

import Combine
import Foundation

private typealias Tuning = AppConfig.IStop

final class IStopFinder: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case snapshot(label: String, done: Int, total: Int)
        case census(looks: Int, groups: Int)
        case sweep(group: Int, of: Int)
        case checking
    }

    @Published private(set) var phase: Phase = .idle

    // State (PCM DID diff)
    /// PCM DIDs that answer (from the scan, kept on the phone).
    @Published private(set) var supported: [String] = []
    @Published private(set) var onSnapshots = 0        // i-stop armed (available)
    @Published private(set) var offSnapshots = 0       // i-stop disabled (OFF switch active)
    @Published private(set) var stateCandidates: [SignalDiff.Candidate] = []
    @Published private(set) var learnedState: BitSignal?

    // Button (bus map + guided sweep)
    /// The bus map: blocks of CAN ids small enough for one look (kept on the phone).
    @Published private(set) var groups: [SweepGroup] = []
    /// Groups swept so far in the last sweep.
    @Published private(set) var sweptGroups = 0
    /// Frames that changed while the OFF button was held, best first.
    @Published private(set) var sweepCandidates: [SweepCandidate] = []
    /// The instruction in large type during the sweep ("HOLD the i-stop OFF button"); nil otherwise.
    @Published private(set) var prompt: String?
    @Published private(set) var learnedFrame: FrameSignal?

    // Modules (read-only)
    @Published private(set) var modules: [ModuleCheck] = []
    /// The start stop unit's as-built lines, FORScan style; empty while not read.
    @Published private(set) var ssuAsBuilt: [String] = []
    /// What 731-01-01 byte B1 bit 4 says about i-stop at start; nil while not read.
    @Published private(set) var ssuIStopDefault: String?

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
    private var sweepShots: [SweepShot] = []
    private var cancelRequested = false
    /// Speaks a sweep prompt (VoiceCoordinator, set by AppModel).
    private let announce: ((String) -> Void)?

    private static let supportedKey = "IStopFinder.supported"
    private static let planKey = "IStopFinder.scanPlan"
    private static let stateKey = "IStopFinder.state"
    private static let frameKey = "IStopFinder.frame"
    private static let groupsKey = "IStopFinder.busMap"

    init(obd: OBDAdapter, controller: IStopController, announce: ((String) -> Void)? = nil) {
        self.obd = obd
        self.controller = controller
        self.announce = announce
        supported = Self.loadSupported()
        groups = Self.loadGroups()
        learnedState = Self.loadState()
        learnedFrame = Self.loadFrame()
        obd.iStopSignal = learnedState
        controller.buttonFrame = learnedFrame
        message = nextStep
    }

    // MARK: Actions

    func scan() { Task { await runScan() } }
    func snapshotState(off: Bool) { Task { await takeStateSnapshot(off: off) } }
    func census() { Task { await runCensus() } }
    func sweep() { Task { await runSweep() } }
    func checkModules() { Task { await runModuleCheck() } }
    func cancel() { cancelRequested = true }

    /// Forget the snapshots and captures taken so far (what's saved stays).
    func resetWork() {
        onShots = []; offShots = []
        onSnapshots = 0; offSnapshots = 0
        stateCandidates = []
        sweepShots = []; sweepCandidates = []; sweptGroups = 0
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
        // The button: a bit set only while held (momentary), from a press that really registered.
        let buttons = sweepCandidates.filter { $0.kind == .momentary && $0.toggled != false }
        if let best = buttons.first {
            let frame = best.frame
            if let data = try? JSONEncoder().encode(frame) {
                UserDefaults.standard.set(data, forKey: Self.frameKey)
            }
            learnedFrame = frame
            controller.buttonFrame = frame
            saved.append("button " + frame.label())
        } else if !sweepCandidates.isEmpty {
            skipped.append("no frame changed only while the button was held (see the list)")
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

    // MARK: Bus map (census)

    /// Maps the bus: looks at all 11-bit ids, and splits every block that overflows the adapter (or is
    /// busier than AppConfig.IStop.maxGroupRate) in two, until each block fits one look. No buttons.
    private func runCensus() async {
        guard canStart(engineRunning: false) else { return }
        cancelRequested = false
        phase = .census(looks: 0, groups: 0)
        message = "Mapping the bus… live data pauses for about a minute. Don't touch any buttons."
        let found: [SweepGroup]? = await obd.runBetweenRounds { [self] (adapter: OBDAdapter) -> [SweepGroup]? in
            var queue: [(base: Int, size: Int)] = [(base: 0, size: 0x800)]
            var mapped: [SweepGroup] = []
            var looks = 0
            while !queue.isEmpty, !cancelRequested {
                let block = queue.removeFirst()
                guard let look = await adapter.captureBlock(base: block.base, size: block.size,
                                                            within: Tuning.censusListen) else { return nil }
                looks += 1
                let rate = Double(look.frames.count) / Tuning.censusListen
                if look.overflowed || rate > Tuning.maxGroupRate, block.size > 1 {
                    let half = block.size / 2
                    queue.insert(contentsOf: [(base: block.base, size: half),
                                              (base: block.base + half, size: half)], at: 0)
                } else if !look.frames.isEmpty {
                    let ids = Array(Set(look.frames.map { $0.id })).sorted()
                    mapped.append(SweepGroup(base: block.base, size: block.size, ids: ids, rate: rate))
                }
                phase = .census(looks: looks, groups: mapped.count)
            }
            return mapped.sorted { $0.base < $1.base }
        } ?? nil
        phase = .idle
        if cancelRequested { message = "Mapping cancelled"; return }
        guard let found else {
            message = "The adapter couldn't capture one block of ids (ATCF/ATCM refused, or live data "
                + "stopped) — see the log."
            return
        }
        groups = found
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: Self.groupsKey) }
        let ids = found.reduce(0) { $0 + $1.ids.count }
        onLog?("i-stop finder: bus map: \(ids) ids in \(found.count) groups: "
               + found.map { $0.label }.joined(separator: ", "))
        sweepShots = []; sweepCandidates = []; sweptGroups = 0
        message = found.isEmpty ? "Nothing heard on the bus — see the log." : nextStep
    }

    // MARK: Guided sweep (the OFF button)

    /// One press per group: released → "Hold" → held → "Release" → released again, the state flag read
    /// before and after. Engine running (a held OFF button with the engine off right after ignition
    /// starts the battery-management reset), parked.
    private func runSweep() async {
        guard canStart(engineRunning: true) else { return }
        guard !groups.isEmpty else { message = "Map the bus first"; return }
        // The OFF button is only held with the engine running: held with the engine off right after
        // ignition, it starts the battery-management reset.
        guard await obd.isEngineRunningForIStop() else {
            message = "Start the engine first (the OFF button is only held with the engine running)"
            return
        }
        let plan = groups
        let state = learnedState
        cancelRequested = false
        sweepShots = []; sweepCandidates = []; sweptGroups = 0
        phase = .sweep(group: 0, of: plan.count)
        let shots: [SweepShot]? = await obd.runBetweenRounds { [self] (adapter: OBDAdapter) -> [SweepShot]? in
            var taken: [SweepShot] = []
            for (index, group) in plan.enumerated() {
                if cancelRequested { break }
                let step = "\(index + 1) of \(plan.count)"
                phase = .sweep(group: index + 1, of: plan.count)
                let before = await readState(adapter, state)
                prompt = "\(step): hands off the buttons…"
                guard let released = await adapter.captureBlock(base: group.base, size: group.size,
                                                                within: Tuning.sweepListen) else { return nil }
                prompt = "\(step): HOLD the i-stop OFF button"
                announce?(Tuning.holdPhrase)
                try? await Task.sleep(for: Tuning.holdLead)
                guard let held = await adapter.captureBlock(base: group.base, size: group.size,
                                                            within: Tuning.sweepHeld) else { return nil }
                prompt = "\(step): RELEASE the button"
                announce?(Tuning.releasePhrase)
                try? await Task.sleep(for: Tuning.releaseLead)
                guard let after = await adapter.captureBlock(base: group.base, size: group.size,
                                                             within: Tuning.sweepListen) else { return nil }
                let afterState = await readState(adapter, state)
                var toggled: Bool?
                if let before, let afterState { toggled = before != afterState }
                taken.append(SweepShot(group: group, before: grouped(released.frames), held: grouped(held.frames),
                                       after: grouped(after.frames), toggled: toggled))
                sweptGroups = taken.count
            }
            return taken
        } ?? nil
        prompt = nil
        phase = .idle
        guard let shots else {
            message = "Live data stopped during the sweep — check the adapter and try again"
            return
        }
        sweepShots = shots
        exportURL = writeExport()
        sweepCandidates = ButtonSweep.analyse(shots)
        let missed = shots.filter { $0.toggled == false }.map { $0.group.label }
        onLog?("i-stop finder: swept \(shots.count) groups, \(sweepCandidates.count) changed frame(s)"
               + (missed.isEmpty ? "" : "; press not registered in " + missed.joined(separator: ", ")))
        for candidate in sweepCandidates.prefix(5) { onLog?("i-stop finder: " + candidate.label) }
        if let best = sweepCandidates.first(where: { $0.kind == .momentary && $0.toggled != false }) {
            message = "Button candidate: \(best.label). Tap Use what was found, then Press OFF now — the "
                + "state above shows whether the car took it."
        } else if sweepCandidates.contains(where: { $0.kind == .latched }) {
            message = "Only the i-stop status echo changed (it stays after release), not the button itself. "
                + (missed.isEmpty ? "" : "The press didn't register in \(missed.count) group(s): sweep again. ")
                + "Export the raw sweep and send it to me."
        } else {
            message = "No frame changed while the button was held"
                + (missed.isEmpty ? "." : " (the press didn't register in \(missed.count) group(s) — sweep again).")
                + " Export the raw sweep and send it to me."
        }
    }

    /// The learned state flag, read inside a job: true = i-stop off. nil without a learned flag.
    private func readState(_ adapter: OBDAdapter, _ signal: BitSignal?) async -> Bool? {
        guard let signal else { return nil }
        let data = await adapter.readDID(signal.did, from: signal.header, complete: false,
                                         timeout: AppConfig.OBD.replyTimeout)
        return signal.isOn(data)
    }

    // MARK: Modules (read-only)

    /// One tester present (3E00) to each module in AppConfig.IStop.moduleChecks; if the start stop unit
    /// answers, its as-built DIDs are read (service 22, read-only) and shown FORScan style.
    private func runModuleCheck() async {
        guard canStart(engineRunning: false) else { return }
        phase = .checking
        let list = Tuning.moduleChecks
        let result: (checks: [ModuleCheck], asBuilt: [String: [UInt8]])? = await obd.runBetweenRounds { adapter in
            var checks: [ModuleCheck] = []
            for module in list {
                let answers = await adapter.answersTesterPresent(module.header)
                checks.append(ModuleCheck(header: module.header, name: module.name, answers: answers))
            }
            var asBuilt: [String: [UInt8]] = [:]
            if checks.contains(where: { $0.header == Tuning.ssuHeader && $0.answers == true }) {
                for did in Tuning.asBuiltDIDs {
                    if let data = await adapter.readDID(did, from: Tuning.ssuHeader, complete: true,
                                                        timeout: AppConfig.OBD.probeTimeout), !data.isEmpty {
                        asBuilt[did] = data
                    }
                }
            }
            return (checks: checks, asBuilt: asBuilt)
        }
        phase = .idle
        guard let result else { message = "Live data stopped during the check — try again"; return }
        modules = result.checks
        ssuAsBuilt = AsBuilt.lines(module: Tuning.ssuHeader, blocks: result.asBuilt)
        ssuIStopDefault = AsBuilt.iStopDefault(result.asBuilt["DE00"])
        let summary = result.checks.map { "\($0.header) " + ($0.answers == true ? "answers" : "silent") }
        onLog?("i-stop finder: modules: " + summary.joined(separator: ", "))
        if !ssuAsBuilt.isEmpty { onLog?("i-stop finder: SSU as-built: " + ssuAsBuilt.joined(separator: " | ")) }
        let ssuAnswers = result.checks.contains { $0.header == Tuning.ssuHeader && $0.answers == true }
        if !ssuAnswers {
            message = "The start stop unit (731) doesn't answer through this adapter: on this car it isn't on "
                + "the bus the KW905 reaches, so its i-stop setting needs an MS-CAN capable adapter."
        } else if ssuAsBuilt.isEmpty {
            message = "The start stop unit answers, but won't hand out its as-built data without a diagnostic "
                + "session (FORScan opens one)."
        } else {
            message = "Start stop unit answers and its as-built block was read (read-only): i-stop "
                + (ssuIStopDefault ?? "default unknown") + "."
        }
    }

    // MARK: Helpers

    private func grouped(_ frames: [(id: String, data: [UInt8])]) -> FrameDiff.Capture {
        var out: FrameDiff.Capture = [:]
        for frame in frames { out[frame.id, default: []].append(frame.data) }
        return out
    }

    private func canStart(engineRunning: Bool = false) -> Bool {
        guard !isBusy else { return false }
        guard obd.isReady else { message = "Connect the adapter and start the engine first"; return false }
        if engineRunning, let speed = obd.sample?.speed, speed >= 1 {
            message = "Stop the car first"
            return false
        }
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
        if groups.isEmpty {
            return "Button: Map the bus (once, no buttons), then the Guided sweep: hold the OFF button each time "
                + "the phone says \"Hold\", let go at \"Release\". (\(state), \(button))"
        }
        return "Button: Guided sweep — \(groups.count) short presses; hold at \"Hold\", let go at \"Release\". "
            + "(\(state), \(button))"
    }

    /// The raw sweep (every group: released / held / released again) as a JSON file to share.
    private func writeExport() -> URL? {
        guard !sweepShots.isEmpty else { return nil }
        func reads(_ capture: FrameDiff.Capture) -> [String: [String]] {
            capture.mapValues { frames in frames.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } }
        }
        var shots: [DoorExport.Shot] = []
        for shot in sweepShots {
            let flipped = shot.toggled.map { $0 ? "state flipped" : "state NOT flipped" } ?? "state unknown"
            let name = "ids " + shot.group.label + " · " + flipped
            shots.append(DoorExport.Shot(scene: name + " · released", reads: reads(shot.before)))
            shots.append(DoorExport.Shot(scene: name + " · held", reads: reads(shot.held)))
            shots.append(DoorExport.Shot(scene: name + " · released again", reads: reads(shot.after)))
        }
        let export = DoorExport(car: "Mazda CX-5 2.2D 2015",
                                takenAt: ISO8601DateFormatter().string(from: Date()), shots: shots)
        guard let data = try? JSONEncoder.pretty.encode(export) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autobot-istop-sweep.json")
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

    private static func loadGroups() -> [SweepGroup] {
        guard let data = UserDefaults.standard.data(forKey: groupsKey) else { return [] }
        return (try? JSONDecoder().decode([SweepGroup].self, from: data)) ?? []
    }

    private static func loadSupported() -> [String] {
        guard UserDefaults.standard.string(forKey: planKey) == SignalDiff.planSignature(Tuning.stateScanPlan) else {
            return []
        }
        return UserDefaults.standard.stringArray(forKey: supportedKey) ?? []
    }
}
