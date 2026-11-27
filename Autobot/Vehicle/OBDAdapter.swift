// OBDAdapter.swift
// Connects to the OBD2 Bluetooth adapter (KONNWEI, ELM327-compatible) and reads road speed and the
// transmission selector. RPM is read only for the DPF monitor. Commands and reply
// parsing: ELM327.swift, MazdaTCM.swift. Live data goes out as `sample` to ManualShiftDetector and
// the lighting monitors.
//
//   ENGINE START -> scan for the adapter (service FFF0, name "KONNWEI") -> connect -> FFF1 notify on
//   -> ATZ + set-up -> "0100" until the engine ECU answers (ignition on)
//   -> which transmission values does the car answer (selector 1E23 or TCM gear 1E12)?
//   -> does the body control module answer its door status (726 22C150)?
//   -> can the climate control unit be reached (733, tester present)? It holds the A/C set
//      temperature; on this car it's on MS-CAN, out of the KW905's reach, so no
//   -> speed and the transmission in a loop -> sample
//      (+ the doors every few rounds -> doorStates)
//      (+ a moment of listening to the bus for the lights frame 09A: the indicators -> turnSignal,
//      the wiper lever -> lightsFrame, read by RainMode)
//      (+ while the wiper lever is in AUTO / INT: the FBCM's wiper motor bit every few rounds
//      -> wiperMotorRunning)
//
// Listening (turn signals, wiper lever): the indicators aren't a value to ask for but a frame the car
// broadcasts, so once a round the adapter monitors the bus for a moment (ATCAF0, ATCRA09A, ATMA … a
// space stops it, ATCAF1) and TurnSignalDetector decides from what it heard (TurnSignals.swift). That
// makes a round a few hundred ms longer (AppConfig.TurnSignals.everyRounds). The wiper lever is in the
// same frame, so it costs nothing on top.
//
// One command at a time: the next one goes out after the ">" prompt (or a timeout; ELMLink.swift, which
// also puts the link back in step after a timeout). Work that needs the adapter for longer (MFinder's /
// DoorFinder's / WiperFinder's scans, snapshots and traces, the DPF reads) runs between two rounds via
// runBetweenRounds, so it never mixes with the live requests; a round of live data always runs between
// two pieces of work.
//
// The lights frame doesn't wait for long work: while work between rounds holds the adapter, its reads
// stop for a look whenever the last one is AppConfig.TurnSignals.maxGapInJobs old, and a flash the bus
// hasn't confirmed for AppConfig.TurnSignals.holdLimit ends by the clock, look or no look. How long
// commands, rounds, looks and the work take is added up (OBDTimings.swift) and logged once a minute.
// If the ECU stops answering (engine off) the set-up starts again; if the adapter disconnects,
// scanning starts again, like the lamp, and while the link isn't up the attempt is started over once
// a minute (ReconnectTimer). Close MAXOBD while driving: both apps would share the
// adapter and get each other's replies.

import Combine
import CoreBluetooth
import SwiftUI

/// One round of live data.
struct OBDSample {
    /// Road speed, km/h (PID 0D); nil if the car doesn't report it.
    let speed: Double?
    /// Gear from the TCM DID 1E12, when the car reports it.
    let gear: Int?
    /// The gear lever (P/R/N/D/M) when the car tells it: from the selector DID (1E23) on cars that
    /// have it, otherwise from the TCM (P/R/N always, D or M once the M flag is learned). nil when
    /// unknown, e.g. driving before the M flag has been learned.
    let selector: ELM327.Selector?
}

/// One line in the optional raw diagnostic (AppConfig.OBD.selectorDiagnostics).
struct SelectorDiag: Identifiable {
    let id: String          // "7E1 221E12"
    let raw: String         // "03" or "—" when the ECU didn't answer
    let changed: Bool       // true for one cycle after the value changed
}

final class OBDAdapter: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published private(set) var status = "OBD: starts with ENGINE START"
    /// True while the adapter's Bluetooth link is up (connected, replies switched on), whether or not
    /// the engine ECU answers yet. The start screen waits for it (BootSequence).
    @Published private(set) var isConnected = false
    /// True while the engine ECU answers and live data comes in.
    @Published private(set) var isReady = false
    /// The latest live data; nil while unknown (not connected, ECU silent).
    @Published private(set) var sample: OBDSample?
    /// Whether the TCM answers its gear value (7E1 221E12: P/R/N and the gear); nil until checked.
    @Published private(set) var reportsTCMGear: Bool?
    /// The latest raw TCM gear code (46 P, 3C R, 32 N, 01…06 gear), for the M finder screen.
    @Published private(set) var tcmGearCode: UInt8?
    /// Live raw transmission values while AppConfig.OBD.selectorDiagnostics is on.
    @Published private(set) var selectorDiag: [SelectorDiag] = []

    /// Which doors are open (empty while unknown: no door signal, or live data stopped). Feeds
    /// DoorMonitor.
    @Published private(set) var doorStates: [DoorMonitor.Opening: Bool] = [:]
    /// Whether the body control module answers the built-in door status (AppConfig.Doors.builtIn,
    /// 726 22C150); nil until checked.
    @Published private(set) var reportsDoors: Bool?
    /// The door signals read every few rounds: the built-in ones the car answers, with the doors
    /// DoorFinder learned in their place.
    @Published private(set) var doorSignals: [DoorMonitor.Opening: BitSignal] = [:]
    /// The latest raw door values, "726 22C150" -> "00 00 80", for the doors screen.
    @Published private(set) var doorRaw: [String: String] = [:]
    /// Whether the climate control unit (AppConfig.Climate.unitHeader) answers through the adapter;
    /// nil until checked. It holds the A/C set temperature; on the 2015 CX-5 it's on the MS-CAN bus,
    /// which the KW905 can't reach, so false is expected with that adapter.
    @Published private(set) var reportsClimateUnit: Bool?
    /// The turn signals / hazard lights, heard on the bus (TurnSignals.swift); nil while unknown (not
    /// listening, the frame not heard, live data stopped). Feeds TurnSignalFlash.
    @Published private(set) var turnSignal: TurnSignals.State?
    /// The lights frame (AppConfig.TurnSignals.frameID) as last heard, set after every look: the
    /// indicators come from it, and the wiper lever (RainMode counts one reading per look). nil while
    /// it isn't heard.
    @Published private(set) var lightsFrame: [UInt8]?
    /// Whether the lights frame (AppConfig.TurnSignals.frameID: indicators, wiper lever) is heard on
    /// the bus; nil until the first look, false also when the adapter can't listen.
    @Published private(set) var hearsLightsFrame: Bool?
    /// Whether the windshield wipers are moving right now, from the front body control module: set
    /// after every reading of `wiperMotorSignal` (published even when unchanged: RainMode times the
    /// wipes from it), nil while it isn't read or didn't answer.
    @Published private(set) var wiperMotorRunning: Bool?
    /// The wiper motor DID's latest reply, "726 22DA0B = 00 10", for the screens.
    @Published private(set) var wiperMotorRaw: String?

    /// The M flag, read every round with the TCM gear: built in (AppConfig.Transmission.mFlag),
    /// or the one MFinder learned.
    var mFlag: BitSignal? = AppConfig.Transmission.mFlag
    /// The doors DoorFinder learned; each one replaces the built-in signal for that door.
    var learnedDoorSignals: [DoorMonitor.Opening: BitSignal] = [:] {
        didSet { updateDoorSignals() }
    }
    /// The wiper motor bit (WiperFinder), read AppConfig.Rain.motorReadsPerRound times a round (and after
    /// work between rounds, AppConfig.Rain.motorReadAfterJobs) while set. RainMode sets it only while the
    /// wiper lever is in AUTO / INT (and the gear lever isn't in M or R), so it costs nothing the rest of
    /// the time.
    var wiperMotorSignal: WiperMotorSignal? {
        didSet {
            if wiperMotorSignal == nil { clearWiperMotor() }
        }
    }

    /// Connection and set-up messages for the dashboard log (not every reading).
    var onLog: ((String) -> Void)?

    private var central: CBCentralManager!
    private var adapter: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private lazy var reconnectTimer = ReconnectTimer { [weak self] in self?.retryConnection() }

    private var session: Task<Void, Never>?
    private let link = ELMLink()          // commands out, replies in, one at a time
    private var useReplyCount = true      // "…1" at the end of requests; false if the adapter says "?"
    private var selectorAvailable = false   // some ECU answers "221E23" (Ford-style P/R/N/D/M)
    private var selectorHeader: String?     // …and which one
    private var tcmGearAvailable = false    // the TCM answers "221E12" (P/R/N + gear)
    private var builtInDoorSignals: [DoorMonitor.Opening: BitSignal] = [:]   // the ones the car answered
    private var currentHeader: String?      // request header the adapter is set to (nil = unknown)
    private var currentReceive: String?     // receive address set with ATCRA (nil = automatic)
    private var receiveFilterUnsupported = false
    private var diagLast: [String: String] = [:]
    private var turnDetector = TurnSignalDetector()
    private var turnLooked = false             // this session's first look (longer, IDs shown) is done
    private var turnShowIDs = true             // show the CAN IDs while listening: the filter let others through
    private var turnListenUnsupported = false  // the adapter refused to listen (ATMA, ATCAF0 or ATCRA)
    private var turnMisses = 0                 // looks in a row without the frame
    private var lightsFrameLength: Int?        // data bytes of the lights frame, from a look that showed the IDs
    private var strayLooksLogged = 0           // looks with stray lines logged this session
    private var turnHold: Task<Void, Never>?   // ends a flash no look has confirmed for holdLimit
    private var isLooking = false              // a look at the lights frame is under way

    /// Work waiting to run between two rounds of live data (runBetweenRounds).
    private struct Job {
        let owner: String                      // who asked, for the timing log: "DPFRecorder"
        let run: () async -> Void
        let cancel: () -> Void
    }
    private var jobs: [Job] = []
    private var jobRunning = false

    // Timing (OBDTimings.swift): added up since the last report.
    private var timings = OBDTimings()
    private var lastTimingReport = ContinuousClock.now
    private var timingReports = 0
    private var lastLookEnded: ContinuousClock.Instant?   // nil: no look yet this session
    private var heldSinceLook: (what: String, seconds: TimeInterval)?   // what held the adapter longest since

    /// One listening window (listen(to:…)): what has been heard so far. The lines come in through
    /// ELMLink.onLine while the ATMA command waits for its prompt.
    private final class Listening {
        let id: String
        let showsIDs: Bool
        /// Without IDs: only lines of this many data bytes are the frame (nil = any).
        let expectedLength: Int?
        let keepListening: ([CANFrame], Date, Date) -> Bool   // frames, started, now
        let started = Date()
        var frames: [CANFrame] = []
        var otherIDs: Set<String> = []     // frames with other IDs that got through
        var strays: [String] = []          // without IDs: hex lines of another length, left out
        var notes: [String] = []           // other lines: "?", "BUFFER FULL", "STOPPED"…
        var ended: Date?                   // when it was decided to stop

        init(id: String, showsIDs: Bool, expectedLength: Int?,
             keepListening: @escaping ([CANFrame], Date, Date) -> Bool) {
            self.id = id
            self.showsIDs = showsIDs
            self.expectedLength = expectedLength
            self.keepListening = keepListening
        }
    }
    private var listening: Listening?

    /// The engine ECU's request header, or the broadcast address when none is set.
    private var baseHeader: String { AppConfig.OBD.requestHeader ?? "7DF" }

    override init() {
        super.init()
        link.onExchange = { [weak self] exchange in self?.noteExchange(exchange) }
        link.onLateReply = { [weak self] in self?.timings.lateReply() }
        link.onResync = { [weak self] recovered in self?.timings.resync(recovered: recovered) }
    }

    /// Turns on Bluetooth and starts looking for the adapter. Called when ENGINE START is pressed.
    func start() {
        if AppConfig.TestMode.enabled {
            status = "OBD: simulated (test mode), no live data"
            isConnected = true
            return
        }
        guard central == nil else { return }
        status = "OBD: waiting for Bluetooth…"
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Exclusive work (MFinder)

    /// Runs `work` between two rounds of live data, with the adapter to itself: nothing else is sent
    /// meanwhile, and live data goes on afterwards. nil if live data isn't running, or stops before
    /// the work could run.
    /// `file` (the caller's, filled in by itself) names the work in the timing log.
    func runBetweenRounds<T>(file: String = #fileID, _ work: @escaping (OBDAdapter) async -> T) async -> T? {
        guard isReady else { return nil }
        let owner = file.split(separator: "/").last?.split(separator: ".").first.map(String.init) ?? file
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            jobs.append(Job(
                owner: owner,
                run: { [unowned self] in
                    let result = await work(self)
                    continuation.resume(returning: result)
                },
                cancel: { continuation.resume(returning: nil) }))
        }
    }

    /// For work in runBetweenRounds: engine RPM (mode 01 PID 0C) from the engine ECU; nil if it didn't
    /// answer. Used by the DPF monitor while its screen is open.
    func readRPM() async -> Double? {
        guard jobRunning, await useHeaderInJob(baseHeader),
              let reply = await request([ELM327.rpmPID]),
              let data = ELM327.values(in: reply, first: ELM327.rpmPID)[ELM327.rpmPID] else {
            return nil
        }
        return ELM327.rpm(data)
    }

    /// One service-22 read for work running in runBetweenRounds: switches the request header as
    /// needed; nil if the ECU didn't answer that DID. `complete` waits for the whole reply (several
    /// frames) instead of returning after the first one.
    func readDID(_ did: String, from header: String, complete: Bool, timeout: TimeInterval) async -> [UInt8]? {
        guard jobRunning, await useHeaderInJob(header) else { return nil }
        let reply = await send22(did, complete: complete, timeout: timeout)
        return reply.flatMap { ELM327.payload22(did, in: $0) }
    }

    /// What a UDS request got back, for scans that care why there's no data.
    enum UDSReply {
        /// Positive response: the data bytes (after "62<DID>" for service 22, "50<session>" for 10).
        case data([UInt8])
        /// Negative response "7F <service> <code>", e.g. 31: no such DID (in this session).
        case refused(UInt8)
        /// No reply, or nothing readable in it.
        case silent
    }

    /// For work in runBetweenRounds: one service-22 read that also tells a refusal ("7F22xx") from
    /// silence. `complete` as in readDID.
    func probeDID(_ did: String, from header: String, complete: Bool, timeout: TimeInterval) async -> UDSReply {
        guard jobRunning, await useHeaderInJob(header),
              let reply = await send22(did, complete: complete, timeout: timeout) else { return .silent }
        if let bytes = ELM327.payload22(did, in: reply) { return .data(bytes) }
        if let code = ELM327.negativeResponseCode(service: 0x22, in: reply) { return .refused(code) }
        // Cut off after the length line of a long reply (the reply count): ask again, to the end.
        if !complete, ELM327.startsLongReply(reply),
           let full = await send22(did, complete: true, timeout: AppConfig.OBD.replyTimeout),
           let bytes = ELM327.payload22(did, in: full) {
            return .data(bytes)
        }
        return .silent
    }

    /// For work in runBetweenRounds: UDS diagnostic session control (service 10) on `header`: 01 the
    /// default session, 03 the extended one (some DIDs only answer there; it only widens what can be
    /// read). The ECU drops back to the default session by itself a few seconds after the last request.
    func diagnosticSession(_ session: UInt8, header: String) async -> UDSReply {
        guard jobRunning, await useHeaderInJob(header),
              let reply = await send(String(format: "10%02X", session)) else { return .silent }
        if let data = ELM327.positiveResponse(service: 0x10, subFunction: session, in: reply) { return .data(data) }
        if let code = ELM327.negativeResponseCode(service: 0x10, in: reply) { return .refused(code) }
        return .silent
    }

    /// For work in runBetweenRounds: the DIDs in `plan` that answer, "726 DA10" style.
    func scanDIDs(_ plan: [(header: String, ranges: [ClosedRange<Int>])], timeout: TimeInterval,
                  progress: (Int, Int) -> Void, cancelled: () -> Bool) async -> [String] {
        let total = plan.reduce(0) { sum, entry in sum + entry.ranges.reduce(0) { $0 + $1.count } }
        var found: [String] = []
        var done = 0
        for entry in plan {
            for range in entry.ranges {
                for value in range {
                    if cancelled() { return found }
                    let did = String(format: "%04X", value)
                    if let bytes = await readDID(did, from: entry.header, complete: false, timeout: timeout),
                       !bytes.isEmpty {
                        found.append("\(entry.header) \(did)")
                    }
                    done += 1
                    if done % 4 == 0 || done == total { progress(done, total) }
                }
            }
        }
        return found
    }

    /// For work in runBetweenRounds: every key ("726 DA10") read `reads` times, in separate passes
    /// so the reads are spread out (values that change by themselves show up as unsteady).
    func snapshotDIDs(_ keys: [String], reads: Int, progress: (Int, Int) -> Void,
                      cancelled: () -> Bool) async -> SignalDiff.Snapshot {
        var snapshot: SignalDiff.Snapshot = [:]
        let total = keys.count * reads
        var done = 0
        for _ in 0..<reads {
            for key in keys {
                if cancelled() { return snapshot }
                if let (header, did) = Self.headerAndDID(key),
                   let bytes = await readDID(did, from: header, complete: true, timeout: AppConfig.OBD.replyTimeout),
                   !bytes.isEmpty {
                    snapshot[key, default: []].append(bytes)
                }
                done += 1
                progress(done, total)
            }
        }
        return snapshot
    }

    /// For work in runBetweenRounds: every frame with this ID heard during `duration` seconds (the wiper
    /// finder's lever check); nil if the adapter can't listen.
    func listenFrames(id: String, duration: TimeInterval) async -> [CANFrame]? {
        guard jobRunning, !turnListenUnsupported, !receiveFilterUnsupported else { return nil }
        let heard = await listen(to: id, showingIDs: turnShowIDs, within: duration) { _, started, now in
            now.timeIntervalSince(started) < duration
        }
        return heard?.frames
    }

    /// For work in runBetweenRounds: `keys` ("726 DA0B", with the data length each returns) read one after
    /// the other, over and over, as fast as the adapter answers, for `duration` seconds: the wiper finder's
    /// trace of one wipe. Each read is timed from the start of the trace; `started` is called just before
    /// the first one goes out. nil if nothing could be asked.
    func traceDIDs(_ keys: [(key: String, length: Int)], duration: TimeInterval, started: () -> Void,
                   cancelled: () -> Bool) async -> [WiperMotorAnalysis.Sample]? {
        guard jobRunning, !keys.isEmpty else { return nil }
        var samples: [WiperMotorAnalysis.Sample] = []
        let start = Date()
        started()
        tracing: while Date().timeIntervalSince(start) < duration {
            for entry in keys {
                if cancelled() || Date().timeIntervalSince(start) >= duration { break tracing }
                guard link.isOpen, !Task.isCancelled else { break tracing }        // the adapter went away
                guard let (header, did) = Self.headerAndDID(entry.key), await useHeader(header) else { continue }
                let asked = Date().timeIntervalSince(start)
                if let reply = await send22(did, complete: entry.length > 4),
                   let data = ELM327.payload22(did, in: reply), !data.isEmpty {
                    samples.append(WiperMotorAnalysis.Sample(time: asked, key: entry.key, data: data))
                }
            }
        }
        return samples
    }

    /// "726 DA10" -> the request header and the DID.
    private static func headerAndDID(_ key: String) -> (header: String, did: String)? {
        let parts = key.split(separator: " ")
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
    }

    /// useHeader for the reads of work between rounds: first a look at the lights frame if the last one
    /// is getting old, so long work doesn't keep the turn signals and the wiper lever waiting.
    private func useHeaderInJob(_ header: String) async -> Bool {
        await lookAtLightsIfOverdue()
        return await useHeader(header)
    }

    /// Runs the next piece of work waiting, with the adapter to itself.
    private func runNextJob() async {
        let job = jobs.removeFirst()
        let started = ContinuousClock.now
        jobRunning = true
        await job.run()
        jobRunning = false
        let seconds = (ContinuousClock.now - started).inSeconds
        timings.job(job.owner, seconds)
        noteHeld(job.owner, seconds)
    }

    /// Live data stopped (or the adapter went away): work still waiting gets nil.
    private func failPendingJobs() {
        let pending = jobs
        jobs.removeAll()
        pending.forEach { $0.cancel() }
    }

    // MARK: Session

    /// Set-up and live data, over and over, until the adapter disconnects (task cancelled).
    private func runSession() async {
        while !Task.isCancelled {
            if await setUp(), await waitForEngine() {
                await checkTransmissionReporting()
                await checkDoorReporting()
                await checkClimateUnit()
                await readLiveData()                   // returns when the ECU stops answering
                reportTimings()
            }
            failPendingJobs()
            isReady = false
            setSample(nil)
            clearDoors()                                      // unknown now
            clearTurnSignals()
            clearWiperMotor()
            try? await Task.sleep(for: AppConfig.OBD.retryDelay)
        }
    }

    /// ATZ and the set-up commands. False if the adapter doesn't answer.
    private func setUp() async -> Bool {
        status = "OBD: setting up the adapter…"
        useReplyCount = true
        currentHeader = nil                            // ATZ resets the adapter's header…
        currentReceive = nil                           // …and receive filter
        receiveFilterUnsupported = false
        turnLooked = false                             // the turn signals get a first look again
        turnShowIDs = true
        turnListenUnsupported = false
        turnMisses = 0
        lightsFrameLength = nil
        strayLooksLogged = 0
        lastLookEnded = nil
        heldSinceLook = nil
        let version = await send(ELM327.reset, timeout: AppConfig.OBD.resetTimeout)
        guard version != nil else {
            logLine("OBD: no answer to \(ELM327.reset)")
            return false
        }
        var results: [String] = []
        for command in ELM327.setupCommands {
            let reply = await send(command)
            if command.hasPrefix("ATSH") {
                currentHeader = ELM327.isOK(reply) ? String(command.dropFirst(4)) : nil
            }
            results.append(command + (ELM327.isOK(reply) ? " OK" : " " + ELM327.readable(reply)))
        }
        logLine("OBD: \(ELM327.version(in: version)) · " + results.joined(separator: ", "))
        return !Task.isCancelled
    }

    /// "0100" until the engine ECU answers (it only does with the ignition on). False if the
    /// adapter stops answering, so the set-up runs again.
    private func waitForEngine() async -> Bool {
        var reportedSilence = false
        while !Task.isCancelled {
            guard let reply = await send(ELM327.wakeCheck, timeout: AppConfig.OBD.probeTimeout) else {
                logLine("OBD: adapter stopped answering")
                return false
            }
            if ELM327.isECUAnswer(reply) {
                logLine("OBD: engine ECU answering")
                return true
            }
            status = "OBD: waiting for the engine (ignition on?)"
            if !reportedSilence {
                logLine("OBD: engine ECU not answering yet (\(ELM327.readable(reply)))")
                reportedSilence = true
            }
            try? await Task.sleep(for: AppConfig.OBD.retryDelay)
        }
        return false
    }

    /// Which selector values does the car answer? Prefer one direct selector DID; otherwise use the
    /// TCM's P/R/N/gear code together with its separate M flag.
    private func checkTransmissionReporting() async {
        selectorAvailable = false
        selectorHeader = nil
        tcmGearAvailable = false
        guard AppConfig.OBD.readSelector, !AppConfig.OBD.selectorDiagnostics else {
            reportsTCMGear = false
            logLine("OBD: transmission read off" + (AppConfig.OBD.selectorDiagnostics ? " (raw diagnostics on)" : ""))
            return
        }
        for header in AppConfig.OBD.selectorHeaders {
            guard await useHeader(header),
                  let reply = await send22(ELM327.selectorDID, timeout: AppConfig.OBD.probeTimeout),
                  let selector = ELM327.selector(in: reply) else { continue }
            selectorAvailable = true
            selectorHeader = header
            logLine("OBD: selector (\(header) 221E23) reported, now \(selector.label); M/D read directly")
            break
        }
        if !selectorAvailable, await useHeader(MazdaTCM.header),
           let reply = await send22(MazdaTCM.gearDID, timeout: AppConfig.OBD.probeTimeout),
           let code = ELM327.payload22(MazdaTCM.gearDID, in: reply)?.first {
            tcmGearAvailable = true
            tcmGearCode = code
            logLine("OBD: TCM gear (7E1 221E12) reported, now " + code.hex
                    + "; P/R/N and gear from it, M/D "
                    + (mFlag.map { "from the M flag (\($0.label(off: "D", on: "M")))" } ?? "unknown (no M flag)"))
        }
        reportsTCMGear = tcmGearAvailable
        if !selectorAvailable, !tcmGearAvailable {
            logLine("OBD: no selector values (221E23, 7E1 221E12); run M finder if the built-in M flag doesn't apply")
        }
        await useHeader(baseHeader)
    }

    /// Does the body control module answer the built-in door status (AppConfig.Doors.builtIn,
    /// 726 22C150)? Each DID is read once to the end of the reply, so its real length is known (a
    /// reply longer than one CAN frame is then always read to the end). Doors whose DID doesn't
    /// answer are left to DoorFinder.
    private func checkDoorReporting() async {
        var working: [DoorMonitor.Opening: BitSignal] = [:]
        var answered: [String] = []
        if AppConfig.Doors.enabled, AppConfig.Doors.readBuiltIn {
            let byDID = Dictionary(grouping: AppConfig.Doors.builtIn) { "\($0.value.header) 22\($0.value.did)" }
            for key in byDID.keys.sorted() {
                guard let group = byDID[key], let first = group.first?.value else { continue }
                var reply: String?
                if await useHeader(first.header) {
                    reply = await send22(first.did, complete: true, timeout: AppConfig.OBD.probeTimeout)
                }
                let needed = (group.map { $0.value.byteIndex }.max() ?? 0) + 1
                guard let data = reply.flatMap({ ELM327.payload22(first.did, in: $0) }), data.count >= needed else {
                    logLine("OBD: door status (\(key)) not answered (\(ELM327.readable(reply))); "
                            + "doors only from the door finder")
                    continue
                }
                for (opening, signal) in group {
                    var known = signal
                    known.length = data.count
                    working[opening] = known
                }
                doorRaw[key] = data.hexString()
                answered.append("\(key) = \(data.hexString())")
            }
            await useHeader(baseHeader)
        }
        builtInDoorSignals = working
        reportsDoors = AppConfig.Doors.enabled ? !working.isEmpty : nil
        if !answered.isEmpty {
            logLine("OBD: door status reported (" + answered.joined(separator: ", ") + "); reading the doors from it")
        }
        updateDoorSignals()
    }

    /// Can the climate control unit be reached (AppConfig.Climate.unitHeader, 733, replies from 73B)?
    /// It holds the A/C set temperature. One "tester present" (3E00): any answer, even a refusal,
    /// means yes. On the 2015 CX-5 it's on the MS-CAN bus (OBD pins 3/11) while the KW905 only
    /// connects to HS-CAN (pins 6/14), so "not answering" is the expected result with that adapter;
    /// an adapter that reaches MS-CAN turns it into "answers". See README, "A/C set temperature".
    private func checkClimateUnit() async {
        guard AppConfig.Climate.enabled, AppConfig.Climate.checkUnit else { return }
        let header = AppConfig.Climate.unitHeader
        var reply: String?
        if await useHeader(header) {
            reply = await send(ELM327.testerPresent)
        }
        await useHeader(baseHeader)
        let answers = reply.map { ELM327.isTesterPresentAnswer($0) } ?? false
        reportsClimateUnit = answers
        if answers {
            logLine("OBD: climate control unit (\(header)) answers (\(ELM327.readable(reply))); "
                    + "its A/C set temperature can be looked for")
        } else {
            logLine("OBD: climate control unit (\(header)) not answering (\(ELM327.readable(reply))): "
                    + "it's on the MS-CAN bus, out of this adapter's reach, so no A/C set temperature")
        }
    }

    /// Speed and the selector, round after round, until the engine ECU stops answering. RPM and pedal
    /// PIDs are not part of this loop. Work queued by runBetweenRounds runs between two rounds.
    private func readLiveData() async {
        status = "OBD: reading live data"
        isReady = true
        timings = OBDTimings()                     // the set-up's commands (ATZ, probes) don't count
        lastTimingReport = .now
        var misses = 0
        var round = 0
        var ranJob = false                         // the last thing done was work between rounds
        while !Task.isCancelled {
            // One piece of work, then a round: however much is waiting, live data keeps its turn.
            if !jobs.isEmpty, !ranJob {
                await runNextJob()
                ranJob = true
                // Work between rounds can take a while (the DPF recorder's reads): a wipe meanwhile
                // shouldn't slip through unseen.
                if AppConfig.Rain.motorReadAfterJobs { _ = await readWiperMotor() }
                continue
            }
            ranJob = false
            let roundStarted = ContinuousClock.now
            let transmission = await readTransmission()
            if transmission.answered {
                // Publish the selector before the independent speed request, so a shift does not
                // wait for a dashboard-only value before it reaches PowerModeController.
                setSample(OBDSample(speed: sample?.speed, gear: transmission.gear,
                                    selector: transmission.selector))
            }
            await useHeader(baseHeader)
            let speedReply = await request([ELM327.speedPID])
            let speed = speedReply
                .flatMap { ELM327.values(in: $0, first: ELM327.speedPID)[ELM327.speedPID]?.first }
                .map { Double($0) }
            if AppConfig.OBD.selectorDiagnostics { selectorDiag = await diagnose() }
            if !doorSignals.isEmpty, round % max(AppConfig.Doors.pollEveryRounds, 1) == 0 {
                await readDoors()
            }
            let thisRound = round
            round += 1
            if speed != nil || transmission.answered {
                misses = 0
                setSample(OBDSample(speed: speed, gear: transmission.gear, selector: transmission.selector))
            } else {
                misses += 1
                if misses >= AppConfig.OBD.maxMissedReadings {
                    logLine("OBD: vehicle stopped answering live-data requests")
                    return
                }
            }
            // The indicators (and the wiper lever) come last, so the live data above goes out without
            // waiting for them; the wiper motor, when it's wanted, right after (the receive filter has to
            // change after listening anyway), and with motorReadsPerRound 2 right before too, so there's
            // rarely more than a second between two reads (a wipe takes about a second).
            var readMotor = false
            if AppConfig.Rain.motorReadsPerRound >= 2 {
                readMotor = await readWiperMotor()
            }
            let listened = await listenToLightsFrame(round: thisRound)
            if AppConfig.Rain.motorReadsPerRound >= 1 {
                let readAfter = await readWiperMotor()
                readMotor = readMotor || readAfter
            }
            timings.round((ContinuousClock.now - roundStarted).inSeconds)
            reportTimingsIfDue()
            if !listened, !readMotor {             // listening to the bus already took its time
                try? await Task.sleep(for: AppConfig.OBD.pollInterval)
            }
        }
    }

    /// The wiper motor bit (`wiperMotorSignal`, set by RainMode while the wiper lever is in AUTO / INT),
    /// AppConfig.Rain.motorReadsPerRound times a round: one service-22 read from the front body control
    /// module. Published after every reading, an unchanged one too. False when it isn't wanted (not read).
    private func readWiperMotor() async -> Bool {
        guard let signal = wiperMotorSignal else { return false }
        var data: [UInt8]?
        if await useHeader(signal.header) {
            let reply = await send22(signal.did, complete: signal.length > 4)
            data = reply.flatMap { ELM327.payload22(signal.did, in: $0) }
        }
        guard wiperMotorSignal == signal else { return true }      // changed meanwhile: this read is stale
        let raw = data.map { "\(signal.header) 22\(signal.did) = " + $0.hexString() }
        if raw != wiperMotorRaw { wiperMotorRaw = raw }
        wiperMotorRunning = signal.isWiping(data)
        return true
    }

    /// Not read any more (lever out of AUTO / INT), live data stopped or the adapter went away: unknown.
    private func clearWiperMotor() {
        if wiperMotorRunning != nil { wiperMotorRunning = nil }
        if wiperMotorRaw != nil { wiperMotorRaw = nil }
    }

    /// The lever and gear for this round: from the selector DID (1E23) on cars that have it,
    /// otherwise from the TCM gear code (1E12) plus the learned M flag.
    private func readTransmission() async -> (selector: ELM327.Selector?, gear: Int?, answered: Bool) {
        if selectorAvailable {
            guard await useHeader(selectorHeader ?? baseHeader) else { return (nil, nil, false) }
            let selector = await send22(ELM327.selectorDID).flatMap { ELM327.selector(in: $0) }
            return (selector, nil, selector != nil)
        }

        // Read the M flag first: it alone confirms M, so do not wait for the separate gear read
        // before turning Power Mode on. A false flag only ends M immediately if the previous state
        // was M; otherwise the gear code is needed to distinguish D from P/R/N for the dashboard.
        var manual: Bool?
        var answered = false
        if let signal = mFlag, await useHeader(signal.header) {
            let bytes = await readSignal(signal)
            manual = signal.isOn(bytes)
            answered = bytes != nil
            if let manual, manual != (sample?.selector == .manual) {     // M just went on, or off
                setSample(OBDSample(speed: sample?.speed, gear: sample?.gear, selector: manual ? .manual : .drive))
            }
        }

        var code: UInt8?
        if tcmGearAvailable, await useHeader(MazdaTCM.header) {
            let reply = await send22(MazdaTCM.gearDID)
            code = reply.flatMap { ELM327.payload22(MazdaTCM.gearDID, in: $0)?.first }
            answered = answered || code != nil
        }
        tcmGearCode = code
        if let code {
            let reading = MazdaTCM.reading(gearCode: code, manual: manual)
            return (reading.selector, reading.gear, answered)
        }
        if let manual { return (manual ? .manual : .drive, nil, answered) }
        return (nil, nil, answered)
    }

    /// A learned signal's DID; the whole reply when it's longer than one CAN frame.
    private func readSignal(_ signal: BitSignal) async -> [UInt8]? {
        let reply = await send22(signal.did, complete: signal.length > 4)
        return reply.flatMap { ELM327.payload22(signal.did, in: $0) }
    }

    /// The door signals: each DID read once (the built-in doors all share 726 22C150), grouped by
    /// ECU so the header changes as little as possible, then every door's bit. A door whose value
    /// doesn't come back keeps its last state. Changes go to the log with the raw value, so a door
    /// on the wrong bit is easy to spot.
    private func readDoors() async {
        let byDID = Dictionary(grouping: doorSignals) { "\($0.value.header) 22\($0.value.did)" }
        var replies: [String: [UInt8]] = [:]
        for key in byDID.keys.sorted() {
            guard let signals = byDID[key], let signal = signals.first?.value,
                  await useHeader(signal.header) else { continue }
            let complete = signals.contains { $0.value.length > 4 }
            if let reply = await send22(signal.did, complete: complete),
               let data = ELM327.payload22(signal.did, in: reply) {
                replies[key] = data
            }
        }
        var raw = doorRaw
        for (key, data) in replies { raw[key] = data.hexString() }
        if raw != doorRaw { doorRaw = raw }

        var states = doorStates
        for (opening, signal) in doorSignals {
            if let isOpen = signal.isOn(replies["\(signal.header) 22\(signal.did)"]) {
                states[opening] = isOpen
            }
        }
        guard states != doorStates else { return }
        logLine("Doors: " + Self.doorChange(from: doorStates, to: states) + " · "
                + replies.keys.sorted().map { "\($0) = \(raw[$0] ?? "")" }.joined(separator: ", "))
        doorStates = states
    }

    /// For the log: "Driver open", "Driver closed, Boot open"; the first reading lists what's open.
    private static func doorChange(from old: [DoorMonitor.Opening: Bool],
                                   to new: [DoorMonitor.Opening: Bool]) -> String {
        if old.isEmpty {
            let open = DoorMonitor.Opening.allCases.filter { new[$0] == true }.map(\.rawValue)
            if !open.isEmpty { return open.joined(separator: ", ") + " open" }
            return new.count == DoorMonitor.Opening.allCases.count ? "all closed" : "closed"
        }
        return DoorMonitor.Opening.allCases.compactMap { opening -> String? in
            guard let isOpen = new[opening], isOpen != old[opening] else { return nil }
            return opening.rawValue + (isOpen ? " open" : " closed")
        }.joined(separator: ", ")
    }

    /// The built-in door signals the car answered, with the learned doors in their place.
    private func updateDoorSignals() {
        let signals = AppConfig.Doors.enabled
            ? builtInDoorSignals.merging(learnedDoorSignals) { _, learned in learned }
            : [:]                                                    // door detection off: read nothing
        guard signals != doorSignals else { return }
        doorSignals = signals
        let known = doorStates.filter { signals[$0.key] != nil }     // a door no longer read is unknown
        if known != doorStates { doorStates = known }
    }

    /// Live data stopped or the adapter went away: the doors are unknown now.
    private func clearDoors() {
        if !doorStates.isEmpty { doorStates = [:] }
        if !doorRaw.isEmpty { doorRaw = [:] }
    }

    /// Optional raw diagnostic: every candidate transmission DID on both ECUs, as raw bytes.
    private func diagnose() async -> [SelectorDiag] {
        var rows: [SelectorDiag] = []
        for candidate in AppConfig.OBD.diagnosticDIDs {
            var reply: String?
            if await useHeader(candidate.header) {
                reply = await send22(candidate.did, timeout: AppConfig.OBD.diagnosticTimeout)
            }
            let bytes = reply.flatMap { ELM327.payload22(candidate.did, in: $0) }
            let raw = bytes?.hexString() ?? "—"
            let key = "\(candidate.header) 22\(candidate.did)"
            let changed = diagLast[key].map { $0 != raw && raw != "—" } ?? false
            diagLast[key] = raw
            rows.append(SelectorDiag(id: key, raw: raw, changed: changed))
        }
        return rows
    }

    // MARK: Lights frame: turn signals and the wiper lever (listening to the bus)

    /// Listens to the bus for the lights frame (AppConfig.TurnSignals.frameID): the turn signals
    /// (`turnSignal`) come from it, and so does the wiper lever (`lightsFrame`, read by RainMode). The
    /// first look of each session lasts `checkListen` with the CAN IDs shown: is the frame there, and
    /// does the adapter keep other frames out while listening? Later looks last as long as
    /// TurnSignalDetector needs (only for the first frame when the turn signals are off and only rain
    /// mode listens). False when it didn't listen this round.
    private func listenToLightsFrame(round: Int) async -> Bool {
        guard listensForLights else { return false }
        let every = hearsLightsFrame == false ? AppConfig.TurnSignals.retryRounds : AppConfig.TurnSignals.everyRounds
        guard round % max(every, 1) == 0 else { return false }
        await lookAtLights()
        return true
    }

    /// Whether the lights frame is listened for at all: a feature wants it and the adapter can.
    private var listensForLights: Bool {
        (AppConfig.TurnSignals.enabled || AppConfig.Rain.enabled) && !turnListenUnsupported && !receiveFilterUnsupported
    }

    /// During work between rounds, before each of its reads: a look, if the last one ended more than
    /// AppConfig.TurnSignals.maxGapInJobs ago. Only while the frame is heard (the session's first look
    /// and the retries after losing it stay with the rounds).
    private func lookAtLightsIfOverdue() async {
        guard jobRunning, listensForLights, hearsLightsFrame == true, let last = lastLookEnded,
              (ContinuousClock.now - last).inSeconds >= AppConfig.TurnSignals.maxGapInJobs else { return }
        await lookAtLights()
    }

    /// One look at the lights frame (see listenToLightsFrame).
    private func lookAtLights() async {
        isLooking = true
        defer { isLooking = false }
        let turnSignalsOn = AppConfig.TurnSignals.enabled
        let id = AppConfig.TurnSignals.frameID
        let firstLook = !turnLooked
        let checkListen = AppConfig.TurnSignals.checkListen
        let firstFrameTimeout = AppConfig.TurnSignals.firstFrameTimeout
        let within = max(AppConfig.TurnSignals.maxListen, checkListen)
        // Without the IDs every hex line counts as the frame, so a line that isn't one (a reply that came
        // in late) could look like a lit indicator or another wiper position: only lines as long as the
        // frame was in a look that showed the IDs count.
        let showIDs = firstLook || turnShowIDs
        let heard = await listen(to: id, showingIDs: showIDs, within: within,
                                 expectedLength: showIDs ? nil : lightsFrameLength) {
            [weak self] frames, started, now in
            guard let self else { return false }
            if firstLook { return now.timeIntervalSince(started) < checkListen }
            if !turnSignalsOn { return frames.isEmpty && now.timeIntervalSince(started) < firstFrameTimeout }
            return self.turnDetector.keepListening(frames, started: started, now: now)
        }
        // Couldn't listen (no answer, refused): nothing heard. A flash then still ends after holdLimit.
        let frames = heard?.frames ?? []
        if let heard, heard.showsIDs, !frames.isEmpty {
            // The frame's length, from frames checked by ID (the most common one: a line cut short when
            // the look stops doesn't count).
            let counts = Dictionary(frames.map { ($0.data.count, 1) }, uniquingKeysWith: +)
            lightsFrameLength = counts.max { $0.value < $1.value }?.key
        }
        if let heard, !heard.strays.isEmpty, strayLooksLogged < 5 {
            strayLooksLogged += 1
            logLine("OBD: left out while listening for \(id) (not \(lightsFrameLength ?? 0) bytes, so not the "
                    + "frame): " + heard.strays.joined(separator: " / "))
        }
        if let heard, firstLook {
            turnLooked = true
            turnShowIDs = !heard.otherIDs.isEmpty          // other frames got through: sort them out by ID
            logFirstLook(heard)
        }
        if frames.isEmpty {
            turnMisses += 1
            let firstLookEmpty = firstLook && heard != nil                 // logged by logFirstLook
            if firstLookEmpty || turnMisses >= AppConfig.TurnSignals.missLimit, hearsLightsFrame != false {
                if !firstLookEmpty {
                    logLine("OBD: lights frame \(id) not heard any more; listening for it every "
                            + "\(AppConfig.TurnSignals.retryRounds) rounds")
                }
                hearsLightsFrame = false
                lightsFrame = nil
            }
        } else {
            if hearsLightsFrame == false, !firstLook { logLine("OBD: lights frame \(id) heard again") }
            hearsLightsFrame = true
            turnMisses = 0
        }
        if let last = frames.last {
            lightsFrame = last.data                         // every look: RainMode counts its readings
        }
        noteLook(frames: frames.count,
                 listened: heard.map { ($0.ended ?? Date()).timeIntervalSince($0.started) } ?? 0)
        guard turnSignalsOn else { return }
        let before = turnDetector.state
        let steadyBefore = turnDetector.steadyBits
        let state = turnDetector.finish(frames, ended: heard?.ended ?? Date())
        let known: TurnSignals.State? = hearsLightsFrame == true ? state : nil
        if known != turnSignal { turnSignal = known }
        if state != before {
            logLine("Turn signals: " + (state.isOn ? "\(state.label) flashing" : "stopped")
                    + " · \(id) byte \(AppConfig.TurnSignals.lampByte): " + lampBytes(frames))
        }
        let newlySteady = turnDetector.steadyBits & ~steadyBefore
        if newlySteady != 0 {
            logLine("Turn signals: \(id) byte \(AppConfig.TurnSignals.lampByte) bit " + newlySteady.hex
                    + " stays lit: taken as a steady light (lights on?), not an indicator")
        }
        restartTurnHold()
    }

    /// A flash lasts until a look says it stopped, or until nothing has confirmed it for
    /// AppConfig.TurnSignals.holdLimit. The detector checks that at the end of every look; this clock
    /// checks it when no look comes (the adapter busy or slow), so the flash can't outlast the car's
    /// indicators by more than holdLimit whatever the link is doing. Started again after every look.
    private func restartTurnHold() {
        turnHold?.cancel()
        turnHold = nil
        guard turnDetector.state.isOn else { return }
        turnHold = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppConfig.TurnSignals.holdLimit + 0.1))
            guard !Task.isCancelled else { return }
            self?.turnHoldEnded()
        }
    }

    private func turnHoldEnded() {
        turnHold = nil
        guard !isLooking else { return }                   // a look is under way: its end decides
        let before = turnDetector.state
        let state = turnDetector.expire(at: Date())
        guard state != before else { return }
        let known: TurnSignals.State? = hearsLightsFrame == true ? state : nil
        if known != turnSignal { turnSignal = known }
        var line = "Turn signals: stopped (no look at the bus confirmed them for "
            + "\(Int(AppConfig.TurnSignals.holdLimit)) s"
        if let held = heldSinceLook { line += "; " + held.what + " took " + OBDTimings.text(held.seconds) }
        timingLine(line + ")")
    }

    /// Listens to the bus for frames with one CAN ID, for as long as `keepListening` says (asked after
    /// every frame and every 50 ms, with the frames so far, the start and the time now). CAN formatting
    /// is off meanwhile, so a broadcast frame shows all its data bytes, and on again afterwards; the
    /// receive filter stays on `id` until the next useHeader puts it back. nil if the adapter refused
    /// (listening is then off for this session, see refuseListening).
    private func listen(to id: String, showingIDs: Bool, within: TimeInterval, expectedLength: Int? = nil,
                        keepListening: @escaping ([CANFrame], Date, Date) -> Bool) async -> Listening? {
        guard await listenSetting(ELM327.formattingOff) else {
            if !turnListenUnsupported { await endListening(showingIDs: false) }   // no answer: make sure it's on
            return nil
        }
        if showingIDs, !(await listenSetting(ELM327.headersOn)) {
            await endListening(showingIDs: false)
            return nil
        }
        guard await listenSetting(ELM327.receiveFilter(id)) else {
            await endListening(showingIDs: showingIDs)
            return nil
        }
        currentReceive = id
        let run = Listening(id: id.uppercased(), showsIDs: showingIDs, expectedLength: expectedLength,
                            keepListening: keepListening)
        listening = run
        link.onLine = { [weak self] line in self?.monitoredLine(line, in: run) }      // frames, as they come in
        let ticker = Task { [weak self] in
            let tick = Duration.milliseconds(50)
            while !Task.isCancelled {
                let asked = ContinuousClock.now
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled else { return }
                // Back much later than asked: the app itself was held up (not the link). For the timing log.
                let late = (ContinuousClock.now - asked - tick).inSeconds
                if late >= AppConfig.OBD.stallThreshold { self?.timings.stall(late) }
                self?.checkListening(run)
            }
        }
        // No prompt in time (the stop got lost?): the next command interrupts the adapter first (ELMLink),
        // so monitoring can't eat it.
        _ = await send(ELM327.monitorAll, timeout: within + 1.5)            // stop + prompt take a moment
        ticker.cancel()
        link.onLine = nil
        listening = nil
        if run.ended == nil { run.ended = Date() }         // stopped by itself (BUFFER FULL…) or no prompt
        if run.notes.contains("?") {
            refuseListening("\(ELM327.monitorAll): ?")
        }
        await endListening(showingIDs: showingIDs)
        return turnListenUnsupported ? nil : run
    }

    /// Asks the window whether to listen on; if not, sends the stop character (the adapter finishes its
    /// line and answers with the prompt, which ends the ATMA command).
    private func checkListening(_ run: Listening) {
        guard listening === run, run.ended == nil,
              !run.keepListening(run.frames, run.started, Date()) else { return }
        run.ended = Date()
        link.interrupt()
    }

    /// One line while listening: a frame with the wanted ID is kept (until it's decided to stop),
    /// other frames are only noted.
    private func monitoredLine(_ line: String, in run: Listening) {
        guard let frame = ELM327.monitoredFrame(line, headers: run.showsIDs) else {
            let note = line.trimmingCharacters(in: .whitespaces)
            if !note.isEmpty, run.notes.count < 20 { run.notes.append(note) }
            return
        }
        guard run.ended == nil else { return }
        if let id = frame.id, id != run.id {
            run.otherIDs.insert(id)
            return
        }
        if frame.id == nil, let expected = run.expectedLength, frame.data.count != expected {
            if run.strays.count < 3 { run.strays.append(ELM327.readable(line)) }
            return
        }
        run.frames.append(CANFrame(time: Date(), data: frame.data))
        checkListening(run)
    }

    /// One AT command for listening. False if it wasn't confirmed; a refusal ("?") switches listening
    /// off for this session.
    private func listenSetting(_ command: String) async -> Bool {
        let reply = await send(command)
        if ELM327.isOK(reply) { return true }
        if let reply, ELM327.isUnknownCommand(reply) { refuseListening("\(command): ?") }
        return false
    }

    /// Back to what the requests need: CAN formatting on, and no IDs in front of the replies.
    private func endListening(showingIDs: Bool) async {
        guard link.isOpen else { return }                      // disconnected: ATZ sets it all up again
        let reply = await send(ELM327.formattingOn)
        if !ELM327.isOK(reply) {
            logLine("OBD: CAN formatting not confirmed back on after listening (\(ELM327.readable(reply)))")
        }
        if showingIDs { _ = await send(ELM327.headersOff) }
    }

    /// The adapter can't listen to the bus: not again this session; the test buttons still work.
    private func refuseListening(_ why: String) {
        guard !turnListenUnsupported else { return }
        turnListenUnsupported = true
        hearsLightsFrame = false
        clearTurnSignals()
        logLine("OBD: the adapter can't listen to the bus (\(why)): no turn signals or wiper lever from "
                + "the car, test buttons only")
    }

    /// The session's first look, for the log: is the frame there, and what else got through?
    private func logFirstLook(_ heard: Listening) {
        let seconds = String(format: "%.1f", AppConfig.TurnSignals.checkListen)
        let others = heard.otherIDs.sorted()
        guard let last = heard.frames.last else {
            var line = "OBD: lights frame \(heard.id) not heard on the bus in \(seconds) s"
            if !others.isEmpty { line += " (other frames got through: " + others.prefix(8).joined(separator: " ") + ")" }
            if !heard.notes.isEmpty { line += " (" + heard.notes.prefix(3).joined(separator: " / ") + ")" }
            logLine(line + "; no turn signals or wiper lever from the car, test buttons only")
            return
        }
        var line = "OBD: lights frame \(heard.id) heard (\(heard.frames.count) in \(seconds) s, "
            + last.data.hexString() + ")"
        if !others.isEmpty {
            line += "; the adapter lets other frames through while listening (\(others.count) IDs), sorted out by ID"
        }
        logLine(line + "; the turn signals and the wiper lever come from it")
    }

    /// "00 20 20 00": the lamp byte of each frame of a look (the last 12), for the log.
    private func lampBytes(_ frames: [CANFrame]) -> String {
        let index = AppConfig.TurnSignals.lampByte
        let bytes = frames.suffix(12).compactMap { frame -> UInt8? in
            frame.data.count > index ? frame.data[index] : nil
        }
        return bytes.isEmpty ? "--" : bytes.hexString()
    }

    /// Live data stopped or the adapter went away: the indicators are unknown now.
    private func clearTurnSignals() {
        turnHold?.cancel()
        turnHold = nil
        turnDetector.reset()
        turnMisses = 0
        if turnSignal != nil { turnSignal = nil }
        if lightsFrame != nil { lightsFrame = nil }
    }

    // MARK: Commands

    /// Points requests at one ECU ("ATSH7E1"); skipped when the adapter is already set to it. ECUs
    /// outside 7E0–7E7 reply outside the 7E8–7EF range the adapter listens to by default (726 -> 72E),
    /// so the adapter is told where to listen ("ATCRA72E"), and back to automatic ("ATAR") after. The
    /// receive filter is checked even when the header stays the same: listening to the bus (turn
    /// signals) leaves it on the frame it listened for.
    @discardableResult
    private func useHeader(_ header: String) async -> Bool {
        let wanted = Self.receiveAddress(for: header)
        let filterSet = receiveFilterUnsupported || wanted == currentReceive
        if currentHeader == header, filterSet { return true }
        if currentHeader != header {
            let reply = await send("ATSH" + header)
            guard ELM327.isOK(reply) else {
                currentHeader = nil
                return false
            }
            currentHeader = header
        }
        if !filterSet {
            let filterReply = await send(wanted.map { "ATCRA" + $0 } ?? "ATAR")
            if ELM327.isOK(filterReply) {
                currentReceive = wanted
            } else if let filterReply, ELM327.isUnknownCommand(filterReply) {
                receiveFilterUnsupported = true
                logLine("OBD: adapter doesn't take ATCRA/ATAR; replies from \(header) may be filtered out")
            }
        }
        return true
    }

    /// Where replies to `header` come from, when the adapter has to be told: nil for the broadcast
    /// address and 7E0–7E7 (their 7E8–7EF replies are heard by default), header + 8 otherwise.
    private static func receiveAddress(for header: String) -> String? {
        guard let value = Int(header, radix: 16) else { return nil }
        if value == 0x7DF || (0x7E0...0x7E7).contains(value) { return nil }
        return String(format: "%03X", value + 8)
    }

    /// A mode 01 request; asked again without the reply count if the adapter doesn't take it.
    private func request(_ pids: [UInt8], timeout: TimeInterval = AppConfig.OBD.replyTimeout) async -> String? {
        await sendCounted(timeout: timeout) { ELM327.request(pids, replyCount: $0) }
    }

    /// A UDS service-22 request ("221E12"). The reply count is left off when `complete` (a reply of
    /// several frames is then read to the end) and dropped for good if the adapter answers "?".
    private func send22(_ did: String, complete: Bool = false,
                        timeout: TimeInterval = AppConfig.OBD.replyTimeout) async -> String? {
        await sendCounted(counted: !complete, timeout: timeout) { ELM327.request22(did, replyCount: $0) }
    }

    /// Sends the request `command` builds, with the reply count ("…1": one reply is enough) when `counted`
    /// and the adapter takes it. If the adapter answers "?", the count is dropped for good and the request
    /// is asked again without it.
    private func sendCounted(counted: Bool = true, timeout: TimeInterval,
                             _ command: (_ replyCount: Bool) -> String) async -> String? {
        let withCount = useReplyCount && counted
        let reply = await send(command(withCount), timeout: timeout)
        guard let reply, withCount, ELM327.isUnknownCommand(reply) else { return reply }
        useReplyCount = false
        logLine("OBD: adapter doesn't take a reply count, asking without it")
        return await send(command(false), timeout: timeout)
    }

    /// Sends one command and waits for the ">" prompt. nil on timeout or when not connected.
    private func send(_ command: String, timeout: TimeInterval = AppConfig.OBD.replyTimeout) async -> String? {
        await link.send(command + "\r", timeout: timeout)
    }

    // MARK: Timing

    /// Every command's round trip, from the link.
    private func noteExchange(_ exchange: ELMLink.Exchange) {
        // Monitoring the bus lasts as long as the look does; it only counts when its prompt never came.
        if exchange.command == ELM327.monitorAll, exchange.answered { return }
        timings.command(exchange)
        if exchange.seconds >= AppConfig.OBD.slowCommand { noteHeld(exchange.command, exchange.seconds) }
    }

    /// Something held the adapter for `seconds`: the longest since the last look at the lights frame is
    /// named when that look comes late.
    private func noteHeld(_ what: String, _ seconds: TimeInterval) {
        if seconds > (heldSinceLook?.seconds ?? 0) { heldSinceLook = (what, seconds) }
    }

    /// A look at the lights frame ended: how long since the one before, and what was in the way.
    private func noteLook(frames: Int, listened: TimeInterval) {
        let now = ContinuousClock.now
        let gap = lastLookEnded.map { (now - $0).inSeconds }
        let held = heldSinceLook.map { $0.what + " " + OBDTimings.text($0.seconds) } ?? ""
        timings.look(gap: gap, held: held, frames: frames, listened: listened)
        if let gap, gap >= AppConfig.OBD.slowLookGap {
            timingLine("OBD timing: lights frame not looked at for " + OBDTimings.text(gap)
                       + (held.isEmpty ? "" : " (" + held + ")"))
        }
        // While the frame isn't heard the looks are far apart on purpose: nothing to measure.
        lastLookEnded = hearsLightsFrame == true ? now : nil
        heldSinceLook = nil
    }

    /// Once every AppConfig.OBD.timingReportInterval, after a round: the minute's timings as one line, to
    /// the file always, to the dashboard log when something is off (and every timingQuietReports-th time).
    private func reportTimingsIfDue() {
        guard (ContinuousClock.now - lastTimingReport).inSeconds >= AppConfig.OBD.timingReportInterval else { return }
        reportTimings()
    }

    private func reportTimings() {
        defer {
            timings = OBDTimings()
            lastTimingReport = .now
        }
        guard !timings.isEmpty else { return }
        let line = "OBD timing: " + timings.summary(lightsFrame: AppConfig.TurnSignals.frameID)
        timingReports += 1
        if timings.isTroubled || timingReports % max(AppConfig.OBD.timingQuietReports, 1) == 1 {
            timingLine(line)
        } else {
            OBDTimingLog.append(line)
        }
    }

    /// A line for the dashboard log and the timing file.
    private func timingLine(_ message: String) {
        OBDTimingLog.append(message)
        logLine(message)
    }

    private func setSample(_ value: OBDSample?) {
        if value == nil, sample == nil { return }      // already unknown
        sample = value
    }

    private func logLine(_ message: String) {
        onLog?(message)
    }

    /// The adapter is gone (or Bluetooth is off): stop the session and forget the reading.
    private func endSession() {
        session?.cancel()
        session = nil
        isConnected = false
        link.close()
        failPendingJobs()
        writeChar = nil
        currentHeader = nil
        currentReceive = nil
        isReady = false
        setSample(nil)
        clearDoors()
        listening = nil
        clearTurnSignals()
        clearWiperMotor()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            endSession()
            adapter = nil
            reconnectTimer.disarm()
            status = "OBD: Bluetooth is off or not authorized"
            return
        }
        startScan()
    }

    private func startScan() {
        status = "OBD: scanning for \(AppConfig.OBD.deviceName)…"
        reconnectTimer.arm()
        // Filtering by service also works while the phone is locked (a nil filter doesn't).
        central.scanForPeripherals(withServices: [ELM327.service])
    }

    /// Forgets the adapter and its session and scans for it again.
    private func startOver() {
        endSession()
        adapter = nil
        startScan()
    }

    /// The link still isn't up a minute after the last attempt (reconnectTimer): drop that attempt
    /// and start over.
    private func retryConnection() {
        guard central.state == .poweredOn else { return }
        logLine("OBD: adapter still not connected, trying again")
        central.cancelAttempt(on: adapter)
        startOver()
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard adapter == nil, name.hasPrefix(AppConfig.OBD.deviceName) else { return }
        c.stopScan()
        adapter = p
        p.delegate = self
        status = "OBD: connecting to \(name)…"
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "OBD: discovering services…"
        p.discoverServices([ELM327.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        startOver()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        logLine("OBD: adapter disconnected")
        startOver()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == ELM327.service }) else {
            status = "OBD: service FFF0 not found"
            return
        }
        p.discoverCharacteristics([ELM327.writeChar, ELM327.notifyChar], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == ELM327.writeChar { writeChar = c }
            if c.uuid == ELM327.notifyChar { p.setNotifyValue(true, for: c) }
        }
        if writeChar == nil { status = "OBD: characteristic FFF2 not found" }
    }

    /// Replies can arrive now: start the set-up.
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == ELM327.notifyChar else { return }
        guard c.isNotifying, writeChar != nil else {
            status = "OBD: could not turn on notifications"
            return
        }
        isConnected = true
        reconnectTimer.disarm()
        guard session == nil else { return }
        logLine("OBD: connected to \(p.name ?? AppConfig.OBD.deviceName)")
        link.open { [weak self] data in
            guard let self, let adapter = self.adapter, let writeChar = self.writeChar else { return }
            adapter.writeValue(data, for: writeChar, type: .withoutResponse)
        }
        session = Task { [weak self] in await self?.runSession() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == ELM327.notifyChar, let value = c.value, !value.isEmpty else { return }
        link.receive(value)
    }
}
