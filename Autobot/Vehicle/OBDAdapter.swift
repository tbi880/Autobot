// OBDAdapter.swift
// Connects to the OBD2 Bluetooth adapter (KONNWEI, ELM327-compatible) and reads road speed and the
// transmission selector. RPM is queried only by i-stop's startup safety check. Commands and reply
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
//      (+ while the wiper lever is in AUTO: the wiper motor bits WiperFinder learned -> wiperMotorRunning)
//      (+ a moment of listening to the bus for the lights frame 09A: the indicators -> turnSignal,
//      the wiper lever -> lightsFrame)
//
// Listening (turn signals): the indicators aren't a value to ask for but a frame the car broadcasts,
// so once a round the adapter monitors the bus for a moment (ATCAF0, ATCRA09A, ATMA … a space stops
// it, ATCAF1) and TurnSignalDetector decides from what it heard (TurnSignals.swift). That makes a
// round a few hundred ms longer (AppConfig.TurnSignals.everyRounds).
//
// One command at a time: the next one goes out after the ">" prompt (or a timeout). Work that needs
// the adapter for longer (MFinder's / DoorFinder's / WiperFinder's scans and snapshots) runs between two
// rounds via runBetweenRounds, so it never mixes with the live requests.
// If the ECU stops answering (engine off) the set-up starts again; if the adapter disconnects,
// scanning starts again, like the lamp. Close MAXOBD while driving: both apps would share the
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
    /// indicators come from it, and the wiper lever (RainMode). nil while it isn't heard.
    @Published private(set) var lightsFrame: [UInt8]?
    /// Whether the lights frame (AppConfig.TurnSignals.frameID: indicators, wiper lever) is heard on the
    /// bus; nil until the first look, false also when the adapter can't listen.
    @Published private(set) var hearsLightsFrame: Bool?
    /// Whether the windshield wipers are wiping right now, from the front body control module: set after
    /// every reading of `wiperMotorSignals` (once a round while RainMode asks for it, i.e. the lever in
    /// AUTO), nil while they aren't read or didn't answer. Feeds RainMode.
    @Published private(set) var wiperMotorRunning: Bool?
    /// Whether i-stop is currently OFF (disabled) as the learned state signal reads it; nil while
    /// unknown (no learned signal, not read yet, live data stopped). Feeds IStopController.
    @Published private(set) var iStopOff: Bool?

    /// The M flag, read every round with the TCM gear: built in (AppConfig.Transmission.mFlag),
    /// or the one MFinder learned.
    var mFlag: BitSignal? = AppConfig.Transmission.mFlag
    /// The doors DoorFinder learned; each one replaces the built-in signal for that door.
    var learnedDoorSignals: [DoorMonitor.Opening: BitSignal] = [:] {
        didSet { updateDoorSignals() }
    }
    /// The wiper motor bits WiperFinder learned, read every round while set: RainMode sets them while the
    /// wiper lever is in AUTO (there the rain sensor decides when to wipe) and clears them otherwise.
    var wiperMotorSignals: [BitSignal] = [] {
        didSet {
            if wiperMotorSignals.isEmpty { clearWiperMotor() }
        }
    }
    /// The learned i-stop state signal (IStopFinder): when set, it's read every few rounds so the
    /// dashboard and IStopController know whether i-stop is on. nil = not learned, state unknown.
    var iStopSignal: BitSignal? {
        didSet { if iStopSignal == nil, iStopOff != nil { iStopOff = nil } }
    }

    /// Connection and set-up messages for the dashboard log (not every reading).
    var onLog: ((String) -> Void)?

    private var central: CBCentralManager!
    private var adapter: CBPeripheral?
    private var writeChar: CBCharacteristic?

    private var session: Task<Void, Never>?
    private var received = ""                                        // reply so far, until ">"
    private var pendingReply: CheckedContinuation<String?, Never>?   // the command waiting for ">"
    private var replyTimeout: Task<Void, Never>?
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

    /// Work waiting to run between two rounds of live data (runBetweenRounds).
    private struct Job {
        let run: () async -> Void
        let cancel: () -> Void
    }
    private var jobs: [Job] = []
    private var jobRunning = false

    /// One listening window (listen(to:…)): what has been heard so far. The lines come in through
    /// peripheral(_:didUpdateValueFor:) while the ATMA command waits for its prompt.
    private final class Listening {
        let id: String
        let showsIDs: Bool
        let captureAll: Bool               // record every frame (by id), not just `id` (bus capture)
        let keepListening: ([CANFrame], Date, Date) -> Bool   // frames, started, now
        let started = Date()
        var frames: [CANFrame] = []
        var allFrames: [(id: String, data: [UInt8])] = []     // every frame heard, while captureAll
        var otherIDs: Set<String> = []     // frames with other IDs that got through
        var notes: [String] = []           // other lines: "?", "BUFFER FULL", "STOPPED"…
        var ended: Date?                   // when it was decided to stop

        init(id: String, showsIDs: Bool, captureAll: Bool = false,
             keepListening: @escaping ([CANFrame], Date, Date) -> Bool) {
            self.id = id
            self.showsIDs = showsIDs
            self.captureAll = captureAll
            self.keepListening = keepListening
        }
    }
    private var listening: Listening?

    /// The engine ECU's request header, or the broadcast address when none is set.
    private var baseHeader: String { AppConfig.OBD.requestHeader ?? "7DF" }

    /// Turns on Bluetooth and starts looking for the adapter. Called when ENGINE START is pressed.
    func start() {
        if AppConfig.TestMode.enabled {
            status = "OBD: simulated (test mode), no live data"
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
    func runBetweenRounds<T>(_ work: @escaping (OBDAdapter) async -> T) async -> T? {
        guard isReady else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            jobs.append(Job(
                run: { [unowned self] in
                    let result = await work(self)
                    continuation.resume(returning: result)
                },
                cancel: { continuation.resume(returning: nil) }))
        }
    }

    /// A single RPM query for i-stop's startup safety gate. RPM is intentionally not part of the
    /// recurring live-data requests; IStopController calls this at most once per second while arming.
    func isEngineRunningForIStop() async -> Bool {
        await runBetweenRounds { adapter in
            guard await adapter.useHeader(adapter.baseHeader),
                  let reply = await adapter.request([ELM327.rpmPID]),
                  let data = ELM327.values(in: reply, first: ELM327.rpmPID)[ELM327.rpmPID] else {
                return false
            }
            return ELM327.rpm(data) >= AppConfig.IStop.minRunningRpm
        } ?? false
    }

    /// One service-22 read for work running in runBetweenRounds: switches the request header as
    /// needed; nil if the ECU didn't answer that DID. `complete` waits for the whole reply (several
    /// frames) instead of returning after the first one.
    func readDID(_ did: String, from header: String, complete: Bool, timeout: TimeInterval) async -> [UInt8]? {
        guard jobRunning, await useHeader(header) else { return nil }
        let reply = await send22(did, complete: complete, timeout: timeout)
        return reply.flatMap { ELM327.payload22(did, in: $0) }
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
                let parts = key.split(separator: " ")
                if parts.count == 2,
                   let bytes = await readDID(String(parts[1]), from: String(parts[0]), complete: true,
                                             timeout: AppConfig.OBD.replyTimeout),
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
    /// finder's snapshots); nil if the adapter can't listen.
    func listenFrames(id: String, duration: TimeInterval) async -> [CANFrame]? {
        guard jobRunning, !turnListenUnsupported, !receiveFilterUnsupported else { return nil }
        let heard = await listen(to: id, showingIDs: turnShowIDs, within: duration) { _, started, now in
            now.timeIntervalSince(started) < duration
        }
        return heard?.frames
    }

    /// For work in runBetweenRounds: every frame heard on the whole bus during `within` seconds, as
    /// (id, data) pairs. Used by the i-stop finder to find the OFF-button frame. Opens the acceptance
    /// mask so every id passes, and puts it back (ATAR) afterwards. nil if the adapter can't listen.
    func captureAllFrames(within: TimeInterval) async -> [(id: String, data: [UInt8])]? {
        guard jobRunning, !turnListenUnsupported, !receiveFilterUnsupported else { return nil }
        let run = await listen(to: "", showingIDs: true, within: within, captureAll: true) { _, started, now in
            now.timeIntervalSince(started) < within
        }
        _ = await send(ELM327.receiveAuto)        // undo the accept-all mask
        currentHeader = nil
        currentReceive = nil
        return run?.allFrames
    }

    /// Replays an observed CAN frame (an experimental i-stop button candidate): sets the header to `id`,
    /// turns CAN formatting and responses off, writes the bytes `count` times `interval` apart, then restores. SHORT press
    /// only — never the 3 s long-press that resets battery management, and IStopController only calls
    /// it once the engine is running. For runBetweenRounds. False if setup or any frame transmission
    /// fails; this confirms only that the adapter accepted the send, not that the car acted on it.
    func injectFrame(id: String, bytes: [UInt8], count: Int, interval: Duration) async -> Bool {
        let canID = id.uppercased()
        guard jobRunning, writeChar != nil,
              canID.count == 3, canID.allSatisfy(\.isHexDigit),
              let numericID = UInt16(canID, radix: 16), numericID <= 0x7FF,
              !bytes.isEmpty, bytes.count <= 8 else {
            logLine("i-stop: can't send frame (invalid CAN ID/data or adapter isn't ready)")
            return false
        }
        guard ELM327.isOK(await send("ATSH" + canID)) else {
            logLine("i-stop: adapter rejected CAN header \(canID)")
            await restoreAfterInject()
            return false
        }
        currentHeader = nil                         // not a request header: drop the tracking
        guard ELM327.isOK(await send(ELM327.formattingOff)) else {
            logLine("i-stop: adapter rejected ATCAF0 (raw CAN mode)")
            await restoreAfterInject()
            return false
        }
        guard ELM327.isOK(await send(ELM327.responsesOff)) else {
            logLine("i-stop: adapter rejected ATR0 (responses off)")
            await restoreAfterInject()
            return false
        }
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        for _ in 0..<max(count, 1) {
            guard let reply = await sendRaw(hex + "\r", timeout: AppConfig.OBD.replyTimeout) else {
                logLine("i-stop: raw CAN transmit timed out; vehicle result is unknown")
                await restoreAfterInject()
                return false
            }
            if ELM327.hasCANTransmitError(reply) {
                logLine("i-stop: adapter rejected raw CAN transmit: \(ELM327.readable(reply))")
                await restoreAfterInject()
                return false
            }
            try? await Task.sleep(for: interval)
        }
        await restoreAfterInject()
        return true
    }

    /// Back to what the requests need after replaying a frame: responses and CAN formatting on, and
    /// the request header / receive filter set again on the next useHeader.
    private func restoreAfterInject() async {
        _ = await send(ELM327.responsesOn)
        _ = await send(ELM327.formattingOn)
        _ = await send(ELM327.receiveAuto)
        currentHeader = nil
        currentReceive = nil
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
            }
            failPendingJobs()
            isReady = false
            setSample(nil)
            clearDoors()                                      // unknown now
            clearTurnSignals()
            clearWiperMotor()
            clearIStop()
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
            logLine("OBD: TCM gear (7E1 221E12) reported, now " + String(format: "%02X", code)
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
                doorRaw[key] = Self.hex(data)
                answered.append("\(key) = \(Self.hex(data))")
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
        var misses = 0
        var round = 0
        while !Task.isCancelled {
            if !jobs.isEmpty {
                let job = jobs.removeFirst()
                jobRunning = true
                await job.run()
                jobRunning = false
                continue
            }
            let transmission = await readTransmission()
            if transmission.answered {
                // Publish the selector before the independent speed request, so a shift does not
                // wait for a dashboard-only value before it reaches PowerModeController.
                setSample(makeSample(speed: sample?.speed, selector: transmission.selector,
                                     gear: transmission.gear))
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
            if !wiperMotorSignals.isEmpty { await readWiperMotor() }
            if let signal = iStopSignal, round % max(AppConfig.IStop.pollEveryRounds, 1) == 0 {
                await readIStop(signal)
            }
            let thisRound = round
            round += 1
            if speed != nil || transmission.answered {
                misses = 0
                setSample(makeSample(speed: speed, selector: transmission.selector, gear: transmission.gear))
            } else {
                misses += 1
                if misses >= AppConfig.OBD.maxMissedReadings {
                    logLine("OBD: vehicle stopped answering live-data requests")
                    return
                }
            }
            // The indicators come last, so the live data above goes out without waiting for them.
            let listened = await listenToLightsFrame(round: thisRound)
            if !listened {                         // listening to the bus already took its time
                try? await Task.sleep(for: AppConfig.OBD.pollInterval)
            }
        }
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
            if let manual, manual, sample?.selector != .manual {
                setSample(makeSample(speed: sample?.speed,
                                     selector: .manual,
                                     gear: sample?.gear))
            } else if let manual, !manual, sample?.selector == .manual {
                setSample(makeSample(speed: sample?.speed,
                                     selector: .drive,
                                     gear: sample?.gear))
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
        for (key, data) in replies { raw[key] = Self.hex(data) }
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

    /// The wiper motor bits (`wiperMotorSignals`), each DID read once: wiping if any of them says so.
    /// Published after every reading, an unchanged one too: RainMode times the wipes from them.
    private func readWiperMotor() async {
        var replies: [String: [UInt8]] = [:]
        var running: Bool?
        for signal in wiperMotorSignals {
            let key = "\(signal.header) 22\(signal.did)"
            if replies[key] == nil, await useHeader(signal.header), let data = await readSignal(signal) {
                replies[key] = data
            }
            if let isOn = signal.isOn(replies[key]) { running = (running ?? false) || isOn }
        }
        wiperMotorRunning = running
    }

    /// Not read any more (lever out of AUTO), live data stopped or the adapter went away: unknown now.
    private func clearWiperMotor() {
        if wiperMotorRunning != nil { wiperMotorRunning = nil }
    }

    /// Reads the learned i-stop state signal and publishes whether i-stop is currently off
    /// (disabled). A change is logged with the raw value.
    private func readIStop(_ signal: BitSignal) async {
        guard await useHeader(signal.header), let data = await readSignal(signal) else { return }
        let off = signal.isOn(data)
        if off != iStopOff {
            if let off {
                logLine("i-stop: " + (off ? "off (disabled)" : "on (armed)") + " · "
                        + signal.label(off: "on", on: "off") + " = " + Self.hex(data))
            }
            iStopOff = off
        }
    }

    /// Live data stopped or the adapter went away: the i-stop state is unknown now.
    private func clearIStop() {
        if iStopOff != nil { iStopOff = nil }
    }

    /// "00 00 80"
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
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
            let raw = bytes.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "—"
            let key = "\(candidate.header) 22\(candidate.did)"
            let changed = diagLast[key].map { $0 != raw && raw != "—" } ?? false
            diagLast[key] = raw
            rows.append(SelectorDiag(id: key, raw: raw, changed: changed))
        }
        return rows
    }

    private func makeSample(speed: Double?, selector: ELM327.Selector?, gear: Int?) -> OBDSample {
        OBDSample(speed: speed, gear: gear, selector: selector)
    }

    // MARK: Lights frame: turn signals and wipers (listening to the bus)

    /// Listens to the bus for the lights frame (AppConfig.TurnSignals.frameID): the turn signals
    /// (`turnSignal`) come from it, and so does the wiper lever (`lightsFrame`, read by RainMode). The
    /// first look of each session lasts `checkListen` with the CAN IDs shown: is the frame there, and
    /// does the adapter keep other frames out while listening? Later looks last as long as
    /// TurnSignalDetector needs. False when it didn't listen this round.
    private func listenToLightsFrame(round: Int) async -> Bool {
        let turnSignalsOn = AppConfig.TurnSignals.enabled
        guard turnSignalsOn || AppConfig.Rain.enabled, !turnListenUnsupported, !receiveFilterUnsupported else {
            return false
        }
        let every = hearsLightsFrame == false ? AppConfig.TurnSignals.retryRounds : AppConfig.TurnSignals.everyRounds
        guard round % max(every, 1) == 0 else { return false }
        let id = AppConfig.TurnSignals.frameID
        let firstLook = !turnLooked
        let checkListen = AppConfig.TurnSignals.checkListen
        let firstFrameTimeout = AppConfig.TurnSignals.firstFrameTimeout
        let within = max(AppConfig.TurnSignals.maxListen, checkListen)
        let heard = await listen(to: id, showingIDs: firstLook || turnShowIDs, within: within) {
            [weak self] frames, started, now in
            guard let self else { return false }
            if firstLook { return now.timeIntervalSince(started) < checkListen }
            if !turnSignalsOn { return frames.isEmpty && now.timeIntervalSince(started) < firstFrameTimeout }
            return self.turnDetector.keepListening(frames, started: started, now: now)
        }
        // Couldn't listen (no answer, refused): nothing heard. A flash then still ends after holdLimit.
        let frames = heard?.frames ?? []
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
                lightsFrame = nil                           // the wiper lever is unknown now
            }
        } else {
            if hearsLightsFrame == false, !firstLook { logLine("OBD: lights frame \(id) heard again") }
            hearsLightsFrame = true
            turnMisses = 0
        }
        if let last = frames.last {
            lightsFrame = last.data                         // every look: RainMode counts its readings
        }
        guard turnSignalsOn else { return true }
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
            logLine("Turn signals: \(id) byte \(AppConfig.TurnSignals.lampByte) bit " + TurnSignals.hex([newlySteady])
                    + " stays lit: taken as a steady light (lights on?), not an indicator")
        }
        return true
    }

    /// Listens to the bus for frames with one CAN ID, for as long as `keepListening` says (asked after
    /// every frame and every 50 ms, with the frames so far, the start and the time now). CAN formatting
    /// is off meanwhile, so a broadcast frame shows all its data bytes, and on again afterwards; the
    /// receive filter stays on `id` until the next useHeader puts it back. nil if the adapter refused
    /// (listening is then off for this session, see refuseListening).
    private func listen(to id: String, showingIDs: Bool, within: TimeInterval, captureAll: Bool = false,
                        keepListening: @escaping ([CANFrame], Date, Date) -> Bool) async -> Listening? {
        guard await listenSetting(ELM327.formattingOff) else {
            if !turnListenUnsupported { await endListening(showingIDs: false) }   // no answer: make sure it's on
            return nil
        }
        if showingIDs || captureAll, !(await listenSetting(ELM327.headersOn)) {
            await endListening(showingIDs: false)
            return nil
        }
        if captureAll {
            _ = await send(ELM327.acceptAllMask)            // every id passes (best effort)
            currentReceive = nil
        } else {
            guard await listenSetting(ELM327.receiveFilter(id)) else {
                await endListening(showingIDs: showingIDs)
                return nil
            }
            currentReceive = id
        }
        let run = Listening(id: id.uppercased(), showsIDs: showingIDs || captureAll,
                            captureAll: captureAll, keepListening: keepListening)
        listening = run
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                self?.checkListening(run)
            }
        }
        let reply = await send(ELM327.monitorAll, timeout: within + 1.5)    // stop + prompt take a moment
        ticker.cancel()
        listening = nil
        if run.ended == nil { run.ended = Date() }         // stopped by itself (BUFFER FULL…) or no prompt
        if reply == nil, writeChar != nil {
            _ = await sendRaw(ELM327.stopMonitoring, timeout: 1)   // stop it again: it mustn't eat the next command
        }
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
        if let adapter, let writeChar {
            adapter.writeValue(Data(ELM327.stopMonitoring.utf8), for: writeChar, type: .withoutResponse)
        }
    }

    /// While listening: every complete line before the prompt goes to the window as soon as it's in.
    private func deliverMonitoredLines(to run: Listening) {
        while let end = received.firstIndex(where: { $0.isNewline }) {
            if let prompt = received.firstIndex(of: ELM327.prompt), prompt < end { return }
            let line = String(received[..<end])
            received.removeSubrange(...end)
            if !line.isEmpty { monitoredLine(line, in: run) }
        }
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
        if run.captureAll {
            if let id = frame.id, run.allFrames.count < 4000 { run.allFrames.append((id: id, data: frame.data)) }
            return
        }
        if let id = frame.id, id != run.id {
            run.otherIDs.insert(id)
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
        guard writeChar != nil else { return }                 // disconnected: ATZ sets it all up again
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
            + TurnSignals.hex(last.data) + ")"
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
        return bytes.isEmpty ? "--" : TurnSignals.hex(bytes)
    }

    /// Live data stopped or the adapter went away: the indicators are unknown now.
    private func clearTurnSignals() {
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
        let reply = await send(ELM327.request(pids, replyCount: useReplyCount), timeout: timeout)
        guard let reply, useReplyCount, ELM327.isUnknownCommand(reply) else { return reply }
        useReplyCount = false
        logLine("OBD: adapter doesn't take a reply count, asking without it")
        return await send(ELM327.request(pids, replyCount: false), timeout: timeout)
    }

    /// A UDS service-22 request ("221E12"). The reply count is left off when `complete` (a reply of
    /// several frames is then read to the end) and dropped for good if the adapter answers "?".
    private func send22(_ did: String, complete: Bool = false,
                        timeout: TimeInterval = AppConfig.OBD.replyTimeout) async -> String? {
        let withCount = useReplyCount && !complete
        let reply = await send(ELM327.request22(did, replyCount: withCount), timeout: timeout)
        guard let reply, withCount, ELM327.isUnknownCommand(reply) else { return reply }
        useReplyCount = false
        logLine("OBD: adapter doesn't take a reply count, asking without it")
        return await send(ELM327.request22(did, replyCount: false), timeout: timeout)
    }

    /// Sends one command and waits for the ">" prompt. nil on timeout or when not connected.
    private func send(_ command: String, timeout: TimeInterval = AppConfig.OBD.replyTimeout) async -> String? {
        await write(command + "\r", timeout: timeout)
    }

    /// Writes `text` as it is (no CR) and waits for the prompt: the stop character for monitoring, when
    /// the adapter didn't answer the first one.
    private func sendRaw(_ text: String, timeout: TimeInterval) async -> String? {
        await write(text, timeout: timeout)
    }

    private func write(_ text: String, timeout: TimeInterval) async -> String? {
        guard let adapter, let writeChar, pendingReply == nil, !Task.isCancelled else { return nil }
        received = ""
        replyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finishReply(nil)
        }
        return await withCheckedContinuation { continuation in
            pendingReply = continuation
            adapter.writeValue(Data(text.utf8), for: writeChar, type: .withoutResponse)
        }
    }

    /// Hands the reply (nil: timeout or disconnected) to the command waiting for it.
    private func finishReply(_ reply: String?) {
        replyTimeout?.cancel()
        replyTimeout = nil
        let waiting = pendingReply
        pendingReply = nil
        waiting?.resume(returning: reply)
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
        finishReply(nil)
        failPendingJobs()
        writeChar = nil
        received = ""
        currentHeader = nil
        currentReceive = nil
        isReady = false
        setSample(nil)
        clearDoors()
        listening = nil
        clearTurnSignals()
        clearWiperMotor()
        clearIStop()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            endSession()
            adapter = nil
            status = "OBD: Bluetooth is off or not authorized"
            return
        }
        startScan()
    }

    private func startScan() {
        status = "OBD: scanning for \(AppConfig.OBD.deviceName)…"
        // Filtering by service also works while the phone is locked (a nil filter doesn't).
        central.scanForPeripherals(withServices: [ELM327.service])
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
        adapter = nil
        startScan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        endSession()
        adapter = nil
        logLine("OBD: adapter disconnected")
        startScan()
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
        guard session == nil else { return }
        logLine("OBD: connected to \(p.name ?? AppConfig.OBD.deviceName)")
        session = Task { [weak self] in await self?.runSession() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == ELM327.notifyChar, let value = c.value, !value.isEmpty else { return }
        received += String(decoding: value, as: UTF8.self)
        if let run = listening { deliverMonitoredLines(to: run) }     // frames, as they come in
        guard let end = received.firstIndex(of: ELM327.prompt) else {
            if received.count > 1024 { received = "" }    // never a prompt: don't grow forever
            return
        }
        let reply = String(received[..<end])
        received = ""
        finishReply(reply)
    }
}
