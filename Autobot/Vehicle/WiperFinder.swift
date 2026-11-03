// WiperFinder.swift
// Finds this car's wiper bits, once, parked with the engine running (dashboard → Rain mode → Wiper finder).
// Two checks, each saved on the phone on its own (Wipers.swift has the why):
//
//   Lever check: frame 09A only, about a minute. Lever OFF → AUTO / INT (dry glass: it wipes once, let it
//   park) → LO → HI → Washer (lever OFF, pulled towards you and held) → OFF once more. Each tap listens to
//   the frame for AppConfig.Rain.leverCheckListen; WiperLeverLayout.learn picks the bits. Until it's
//   saved, the built-in layout (byte 4: 0x02 LO contact, 0x04 INT contact) is used.
//
//   Wiper motor (front body control module 726), only needed for AUTO / INT:
//     1. Scan once: which of the FBCM's DIDs answer (AppConfig.Rain.motorScanPlan; kept on the phone,
//        the earlier wiper finder's scan is reused)
//     2. Parked: lever OFF, wipers parked → every DID read twice
//     3. Wiping: a quick spray, lever in LO, keep it wiping → every DID read twice. The bits that read
//        differently are the candidates (where the earlier finder stopped, with 9–10 of them)
//     4. Trace a wipe, twice: lever OFF, tap Trace, then right away lever → AUTO and hold it there. The
//        candidates' DIDs are read over and over for AppConfig.Rain.traceDuration; only bits that leave
//        their parked value with that one wipe and come back are the motor (WiperMotorAnalysis.solve).
//
// Everything runs between two rounds of live data (OBDAdapter.runBetweenRounds), like the M finder.

import Combine
import Foundation

private typealias Tuning = AppConfig.Rain

final class WiperFinder: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening(String)                              // lever check: listening to frame 09A
        case scanning(done: Int, total: Int)                // FBCM scan
        case reading(label: String, done: Int, total: Int)  // FBCM snapshot
        case waitingForTrace                                // the trace waits for the end of a round
        case tracing(until: Date)                           // a wipe trace runs: move the lever now
    }

    @Published private(set) var phase: Phase = .idle
    /// What just happened, for the screen.
    @Published private(set) var message = ""

    // Lever check
    /// Takes per step so far.
    @Published private(set) var leverTakes: [WiperLeverLayout.Step: Int] = [:]
    /// What the takes so far make of the lever.
    @Published private(set) var leverResult = WiperLeverLayout.CheckResult()
    /// The saved layout; nil = the built-in one is in use.
    @Published private(set) var learnedLever: WiperLeverLayout?

    // Wiper motor
    /// The FBCM has been scanned (with the current scan plan)…
    @Published private(set) var scanned = false
    /// …and these DIDs answered, "726 DA10" style.
    @Published private(set) var motorDIDs: [String] = []
    @Published private(set) var parkedCount = 0
    @Published private(set) var wipingCount = 0
    /// Bits that read differently parked and wiping, best first.
    @Published private(set) var candidates: [WiperMotorAnalysis.Candidate] = []
    @Published private(set) var traceCount = 0
    /// What the traces make of the candidates.
    @Published private(set) var motorResult = WiperMotorAnalysis.Result()
    /// The saved motor bit; nil = not found, AUTO / INT doesn't count.
    @Published private(set) var learnedMotor: WiperMotorSignal?

    /// Everything taken so far as a JSON file to share; nil until there is something.
    @Published private(set) var exportURL: URL?

    /// Results for the dashboard log.
    var onLog: ((String) -> Void)?

    var isBusy: Bool { phase != .idle }
    /// The lever layout rain mode uses now.
    var leverInUse: WiperLeverLayout { learnedLever ?? .builtIn }

    private let obd: OBDAdapter
    private let rain: RainMode
    private var frames: [WiperLeverLayout.Step: [[[UInt8]]]] = [:]
    private var parked: [SignalDiff.Snapshot] = []
    private var wiping: [SignalDiff.Snapshot] = []
    private var traces: [[WiperMotorAnalysis.Sample]] = []
    private var cancelRequested = false

    private static let leverKey = "Wipers.leverLayout"
    private static let motorKey = "Wipers.motorSignal"
    /// The FBCM scan: the same keys and plan as the earlier wiper finder, so its scan is still good.
    private static let motorDIDsKey = "WiperFinder.motorDIDs"
    private static let motorPlanKey = "WiperFinder.motorPlan"
    /// What the earlier wiper finder saved, in its own format: not used any more.
    private static let oldKeys = ["WiperFinder.signal", "WiperFinder.motor"]

    /// The indicator lamp bits never count as lever bits.
    private static var ignoredFrameBits: [Int: UInt8] {
        [AppConfig.TurnSignals.lampByte: AppConfig.TurnSignals.leftBits | AppConfig.TurnSignals.rightBits]
    }

    init(obd: OBDAdapter, rain: RainMode) {
        self.obd = obd
        self.rain = rain
        for key in Self.oldKeys { UserDefaults.standard.removeObject(forKey: key) }
        learnedLever = Self.load(WiperLeverLayout.self, key: Self.leverKey)
        learnedMotor = Self.load(WiperMotorSignal.self, key: Self.motorKey)
        if let found = Self.loadMotorDIDs() {
            scanned = true
            motorDIDs = found
        }
        rain.leverLayout = learnedLever ?? .builtIn
        rain.motorSignal = learnedMotor
    }

    // MARK: Lever check

    func checkLever(_ step: WiperLeverLayout.Step) { Task { await listen(step) } }

    /// Saves the layout the check found; rain mode reads the lever with it from now on.
    func useLever() {
        guard let layout = leverResult.layout else { return }
        Self.save(layout, key: Self.leverKey)
        learnedLever = layout
        rain.leverLayout = layout
        message = "Saved: rain mode reads the lever with these bits now."
        onLog?("Wiper finder: lever saved · " + layout.descriptions.joined(separator: " · "))
    }

    /// Back to the built-in layout.
    func forgetLever() {
        UserDefaults.standard.removeObject(forKey: Self.leverKey)
        learnedLever = nil
        rain.leverLayout = .builtIn
        message = "Forgotten: the built-in lever layout is used again."
        onLog?("Wiper finder: lever forgotten, built-in layout (09A byte 4 & 06)")
    }

    /// Forgets the lever takes so far (what was saved stays).
    func resetLever() {
        frames = [:]
        leverTakes = [:]
        leverResult = WiperLeverLayout.CheckResult()
        exportURL = writeExport()
        message = ""
    }

    /// The next lever step, for the screen.
    var leverHint: String {
        func taken(_ step: WiperLeverLayout.Step) -> Int { leverTakes[step] ?? 0 }
        if taken(.off) == 0 { return "Lever OFF, wipers parked → tap OFF" }
        if taken(.auto) == 0 {
            return "Lever in AUTO / INT on dry glass (it wipes once: wait until it has parked) → tap AUTO / INT"
        }
        if taken(.low) == 0 { return "A quick spray, then the lever in LO → tap LO" }
        if taken(.high) == 0 { return "Lever in HI → tap HI" }
        if taken(.washer) == 0 { return "Lever OFF, pull it towards you and hold it → tap Washer (optional)" }
        if taken(.off) < 2 { return "Lever OFF, wipers parked → tap OFF once more" }
        if leverResult.layout == nil { return "No layout yet: see the notes, or take the steps again" }
        if learnedLever == leverResult.layout { return "Saved: rain mode reads the lever with these bits." }
        return "Found: tap Use it"
    }

    private func listen(_ step: WiperLeverLayout.Step) async {
        guard canStart() else { return }
        cancelRequested = false
        phase = .listening(step.label)
        let id = AppConfig.TurnSignals.frameID
        let duration = Tuning.leverCheckListen
        let result = await obd.runBetweenRounds { (adapter: OBDAdapter) -> [CANFrame]? in
            await adapter.listenFrames(id: id, duration: duration)
        }
        phase = .idle
        guard let heard = result.flatMap({ $0 }), let last = heard.last else {
            message = "Frame \(id) not heard: is live data running (engine on, adapter connected)?"
            return
        }
        frames[step, default: []].append(heard.map(\.data))
        leverTakes[step, default: 0] += 1
        leverResult = WiperLeverLayout.learn(frames, ignored: Self.ignoredFrameBits)
        exportURL = writeExport()
        onLog?("Wiper finder: lever \(step.label) · \(id) = " + Wipers.hex(last.data) + " (\(heard.count) frames)")
        message = "\(step.label): \(heard.count) frames, last " + Wipers.hex(last.data)
    }

    // MARK: Wiper motor

    func scan() { Task { await runScan() } }
    func snapshotParked() { Task { await snapshot(wiping: false) } }
    func snapshotWiping() { Task { await snapshot(wiping: true) } }
    func traceWipe() { Task { await trace() } }
    func cancel() { cancelRequested = true }

    /// Saves the motor bit the traces found; rain mode reads it while the lever is in AUTO / INT.
    func useMotor() {
        guard let signal = motorResult.signal else { return }
        Self.save(signal, key: Self.motorKey)
        learnedMotor = signal
        rain.motorSignal = signal
        message = "Saved: in AUTO / INT rain mode follows the wiper motor now."
        onLog?("Wiper finder: wiper motor saved · " + signal.label)
    }

    /// No motor bit any more: AUTO / INT doesn't count as rain.
    func forgetMotor() {
        UserDefaults.standard.removeObject(forKey: Self.motorKey)
        learnedMotor = nil
        rain.motorSignal = nil
        message = "Forgotten: AUTO / INT doesn't count as rain until a motor bit is saved."
        onLog?("Wiper finder: wiper motor forgotten (AUTO / INT doesn't count)")
    }

    /// Forgets the motor snapshots and traces so far (the scan and what was saved stay).
    func resetMotor() {
        parked = []
        wiping = []
        traces = []
        parkedCount = 0
        wipingCount = 0
        traceCount = 0
        candidates = []
        motorResult = WiperMotorAnalysis.Result()
        exportURL = writeExport()
        message = ""
    }

    /// The next motor step, for the screen.
    var motorHint: String {
        if !scanned { return "Scan the front body control module (once, a few minutes)" }
        if motorDIDs.isEmpty { return "The scan found no FBCM DIDs: widen AppConfig.Rain.motorScanPlan" }
        if parkedCount == 0 { return "Lever OFF, wipers parked → tap Parked" }
        if wipingCount == 0 { return "A quick spray, lever in LO, keep it wiping → tap Wiping" }
        if candidates.isEmpty { return "Nothing differs between parked and wiping: take Wiping again while it wipes" }
        if traceCount == 0 || motorResult.signal == nil {
            return "Lever OFF, wipers parked → tap Trace, then at once lever → AUTO / INT and hold it there"
        }
        if learnedMotor == motorResult.signal { return "Saved: AUTO / INT follows the wiper motor." }
        if motorResult.bestPulses < Tuning.tracesToConfirm {
            return "Found, not confirmed yet: lever back to OFF → Trace once more (or Use it already)"
        }
        return "Found and confirmed: tap Use it"
    }

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
        resetMotor()
        message = usable.isEmpty
            ? "No DIDs answered in AppConfig.Rain.motorScanPlan (see the log): widen it, or check the adapter hears 72E."
            : "\(usable.count) FBCM DIDs answer."
    }

    /// Every scanned DID, read `motorReadsPerSnapshot` times: parked, or wiping in LO.
    private func snapshot(wiping isWiping: Bool) async {
        guard canStart() else { return }
        guard scanned, !motorDIDs.isEmpty else {
            message = "Scan the front body control module first."
            return
        }
        cancelRequested = false
        let label = isWiping ? "Wiping (LO)" : "Parked (OFF)"
        let keys = motorDIDs
        let reads = max(Tuning.motorReadsPerSnapshot, 1)
        phase = .reading(label: label, done: 0, total: keys.count * reads)
        let taken: SignalDiff.Snapshot? = await obd.runBetweenRounds { [self] adapter in
            await adapter.snapshotDIDs(keys, reads: reads,
                                       progress: { done, total in
                                           phase = .reading(label: label, done: done, total: total)
                                       },
                                       cancelled: { cancelRequested })
        }
        phase = .idle
        if cancelRequested {
            message = "Cancelled"
            return
        }
        guard let taken, !taken.isEmpty else {
            message = "\(label): the front body control module didn't answer. Try again."
            return
        }
        if isWiping {
            wiping.append(taken)
            wipingCount = wiping.count
        } else {
            parked.append(taken)
            parkedCount = parked.count
        }
        solveMotor()
        exportURL = writeExport()
        let differ = candidates.isEmpty ? "" : " · \(candidates.count) bits in "
            + "\(Set(candidates.map(\.key)).count) DIDs differ between parked and wiping"
        onLog?("Wiper finder: \(label) · \(taken.count) FBCM DIDs read" + differ)
        message = "\(label): \(taken.count) DIDs read" + differ
    }

    /// The candidates' DIDs read over and over while the lever goes OFF → AUTO (one wipe).
    private func trace() async {
        guard canStart() else { return }
        let keys = WiperMotorAnalysis.traceKeys(candidates, after: motorResult, limit: Tuning.traceMaxDIDs)
        guard !keys.isEmpty else {
            message = "Take Parked and Wiping first: they pick the DIDs to trace."
            return
        }
        cancelRequested = false
        let duration = Tuning.traceDuration
        phase = .waitingForTrace
        message = "Get ready: lever OFF, hand on the lever…"
        let result: [WiperMotorAnalysis.Sample]?? = await obd.runBetweenRounds { [self] adapter in
            await adapter.traceDIDs(keys, duration: duration,
                                    started: {
                                        phase = .tracing(until: Date().addingTimeInterval(duration))
                                        message = "NOW: lever → AUTO / INT, and hold it there"
                                    },
                                    cancelled: { cancelRequested })
        }
        phase = .idle
        if cancelRequested {
            message = "Cancelled"
            return
        }
        guard let samples = result.flatMap({ $0 }), !samples.isEmpty else {
            message = "The trace got no answers from the FBCM. Try again."
            return
        }
        traces.append(samples)
        traceCount = traces.count
        solveMotor()
        exportURL = writeExport()
        let found = motorResult.signal.map { "wiping = " + $0.label } ?? "no bit came and went with the wipe"
        onLog?("Wiper finder: trace \(traceCount) · \(samples.count) reads of \(keys.count) DIDs in "
               + "\(Int(duration)) s · " + found)
        message = "Trace \(traceCount): \(samples.count) reads of \(keys.count) DIDs · " + found
            + ". Lever back to OFF."
    }

    private func solveMotor() {
        candidates = WiperMotorAnalysis.candidates(parked: parked, wiping: wiping, ignored: Tuning.motorIgnoredDIDs)
        motorResult = WiperMotorAnalysis.solve(candidates: candidates, traces: traces, timing: Tuning.traceTiming)
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

    /// Everything taken so far as a shareable JSON file; nil if there's nothing or it can't be written.
    private func writeExport() -> URL? {
        guard !frames.isEmpty || !parked.isEmpty || !wiping.isEmpty || !traces.isEmpty else { return nil }
        var lever: [WiperExport.LeverTake] = []
        for step in WiperLeverLayout.Step.allCases {
            for take in frames[step] ?? [] {
                lever.append(WiperExport.LeverTake(step: step.label, frames: take.map { Wipers.hex($0) }))
            }
        }
        func motorSnapshot(_ snapshot: SignalDiff.Snapshot, _ label: String) -> WiperExport.MotorSnapshot {
            WiperExport.MotorSnapshot(label: label, reads: snapshot.mapValues { reads in reads.map { Wipers.hex($0) } })
        }
        let motor = parked.map { motorSnapshot($0, "Parked (OFF)") } + wiping.map { motorSnapshot($0, "Wiping (LO)") }
        let traced = traces.map { trace in
            trace.map { WiperExport.TraceRead(t: ($0.time * 1000).rounded() / 1000, key: $0.key, data: Wipers.hex($0.data)) }
        }
        let export = WiperExport(car: "Mazda CX-5 2.2D 2015", takenAt: ISO8601DateFormatter().string(from: Date()),
                                 lever: lever, motor: motor, traces: traced)
        guard let data = try? JSONEncoder.pretty.encode(export) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autobot-wiper-finder.json")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The scan result, if there is one made with the current scan plan.
    private static func loadMotorDIDs() -> [String]? {
        guard UserDefaults.standard.string(forKey: motorPlanKey) == SignalDiff.planSignature(Tuning.motorScanPlan) else {
            return nil
        }
        return UserDefaults.standard.stringArray(forKey: motorDIDsKey)
    }
}
