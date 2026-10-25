// OBDAdapter.swift
// Connects to the OBD2 Bluetooth adapter (KONNWEI, ELM327-compatible) and reads live data from
// the engine ECU a few times a second: RPM, road speed, the accelerator pedal (or the engine load)
// and, if the car has it, the gear. Commands and reply parsing: ELM327.swift. The data goes out
// as `sample` to ManualShiftDetector and EngineMonitor.
//
//   ENGINE START -> scan for the adapter (service FFF0, name "KONNWEI") -> connect -> FFF1 notify on
//   -> ATZ + set-up -> "0100" until the engine ECU answers (ignition on)
//   -> which PIDs does it have (0100, 0120, …, logged) -> does any ECU report the gear (PID A4)?
//   -> "010C0D" (RPM + speed) and the pedal (+ the gear) in a loop -> sample
//
// One command at a time: the next one goes out after the ">" prompt (or a timeout).
// If the ECU stops answering (engine off) the set-up starts again; if the adapter disconnects,
// scanning starts again, like the lamp. Close MAXOBD while driving: both apps would share the
// adapter and get each other's replies.

import Combine
import CoreBluetooth
import SwiftUI

/// One round of live data from the engine ECU.
struct OBDSample {
    let time: Date
    /// Engine speed, r/min.
    let rpm: Double
    /// Road speed, km/h (PID 0D); nil if the car doesn't report it.
    let speed: Double?
    /// How hard the accelerator is pressed, 0–100 %: pedal PID 5A or 49, otherwise engine load 04.
    let demand: Double?
    /// Gear from PID A4, when the engine ECU reports it.
    let gear: Int?
}

final class OBDAdapter: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published private(set) var status = "OBD: starts with ENGINE START"
    /// True while the engine ECU answers and live data comes in.
    @Published private(set) var isReady = false
    /// The latest live data; nil while unknown (not connected, ECU silent).
    @Published private(set) var sample: OBDSample?
    /// Mode 01 PIDs the engine ECU supports (empty until asked).
    @Published private(set) var supportedPIDs: Set<UInt8> = []
    /// Where `sample.demand` comes from, for the dashboard: "pedal (PID 5A)", "engine load (PID 04)"…
    @Published private(set) var demandSource: String?
    /// Whether the car reports the current gear (standard PID A4); nil until checked.
    @Published private(set) var reportsGear: Bool?

    /// Latest engine speed (r/min); nil while unknown.
    var rpm: Double? { sample?.rpm }

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
    private var combineRequests = true    // "010C0D"; false if the ECU answers one PID per request
    private var demandPID: UInt8?
    private var gearFromECU = false
    private var pedalReleased: Double?    // PID 49: lowest value seen, i.e. the pedal released
    private var pedalFloored = 80.0       // PID 49: highest value seen, at least 80 %

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

    // MARK: Session

    /// Set-up and live data, over and over, until the adapter disconnects (task cancelled).
    private func runSession() async {
        while !Task.isCancelled {
            if await setUp(), await waitForEngine() {
                await discoverSupportedPIDs()
                await checkGearReporting()
                await readLiveData()                   // returns when the ECU stops answering
            }
            isReady = false
            setSample(nil)
            try? await Task.sleep(for: AppConfig.OBD.retryDelay)
        }
    }

    /// ATZ and the set-up commands. False if the adapter doesn't answer.
    private func setUp() async -> Bool {
        status = "OBD: setting up the adapter…"
        useReplyCount = true
        combineRequests = true
        let version = await send(ELM327.reset, timeout: AppConfig.OBD.resetTimeout)
        guard version != nil else {
            logLine("OBD: no answer to \(ELM327.reset)")
            return false
        }
        var results: [String] = []
        for command in ELM327.setupCommands {
            let reply = await send(command)
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

    /// Asks the engine ECU which mode 01 PIDs it has: 0100, then 0120, 0140… as long as each block
    /// lists the next one. Picks where the pedal comes from and logs the list.
    private func discoverSupportedPIDs() async {
        var found: Set<UInt8> = []
        var base: UInt8 = 0x00
        while !Task.isCancelled {
            guard let reply = await request([base], timeout: AppConfig.OBD.probeTimeout),
                  let pids = ELM327.supportedPIDs(in: reply, base: base) else { break }
            found.formUnion(pids)
            guard base < 0xC0, pids.contains(base + 0x20) else { break }
            base += 0x20
        }
        supportedPIDs = found
        if found.isEmpty {
            demandPID = ELM327.loadPID                 // list unknown: engine load, nearly every car has it
        } else {
            demandPID = [ELM327.relativePedalPID, ELM327.pedalPID, ELM327.loadPID].first { found.contains($0) }
        }
        gearFromECU = found.contains(ELM327.gearPID)
        demandSource = demandPID.map { Self.demandName($0) }
        logLine("OBD: engine ECU has \(found.count) PIDs: "
                + found.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))
        logLine("OBD: reading RPM, speed, \(demandSource ?? "no pedal")" + (gearFromECU ? ", gear (PID A4)" : ""))
    }

    private static func demandName(_ pid: UInt8) -> String {
        switch pid {
        case ELM327.relativePedalPID: return "pedal (PID 5A)"
        case ELM327.pedalPID: return "pedal (PID 49)"
        default: return "engine load (PID 04)"
        }
    }

    /// Does any ECU report the gear (PID A4)? Shown on the dashboard; the gear itself is only read
    /// when the engine ECU has it (otherwise ManualShiftDetector works it out from RPM ÷ speed).
    private func checkGearReporting() async {
        if gearFromECU {
            reportsGear = true
            logLine("OBD: gear (PID A4) reported by the engine ECU")
            return
        }
        let directHeader = AppConfig.OBD.requestHeader
        if directHeader != nil { _ = await send(ELM327.broadcastHeader) }   // ask every ECU
        let reply = await send(ELM327.gearCheck, timeout: AppConfig.OBD.probeTimeout)
        if let directHeader { _ = await send("ATSH" + directHeader) }     // back to the engine ECU
        let reports = reply.flatMap { ELM327.reportsGear($0) } ?? false
        reportsGear = reports
        logLine("OBD: gear (PID A4) " + (reports ? "reported by another ECU, not read; gear from RPM ÷ speed"
                                                 : "not reported by the car; gear from RPM ÷ speed"))
    }

    /// RPM + speed, the pedal and (if the engine ECU has it) the gear, round after round, until the
    /// engine ECU stops answering.
    private func readLiveData() async {
        status = "OBD: reading live data"
        isReady = true
        var misses = 0
        while !Task.isCancelled {
            var values: [UInt8: [UInt8]] = [:]
            for group in requestGroups() {
                guard let first = group.first, let reply = await request(group) else { continue }
                let found = ELM327.values(in: reply, first: first)
                if combineRequests, group.count > 1, found[first] != nil, found.count < group.count {
                    combineRequests = false
                    logLine("OBD: the ECU answers one PID per request, asking separately")
                }
                values.merge(found) { _, new in new }
            }
            if let rpmData = values[ELM327.rpmPID] {
                misses = 0
                setSample(makeSample(values, rpmData: rpmData))
            } else {
                misses += 1
                if misses >= AppConfig.OBD.maxMissedReadings {
                    logLine("OBD: engine ECU stopped answering")
                    return
                }
            }
            try? await Task.sleep(for: AppConfig.OBD.pollInterval)
        }
    }

    /// The requests for one round, each small enough for a single CAN frame.
    private func requestGroups() -> [[UInt8]] {
        let hasSpeed = supportedPIDs.isEmpty || supportedPIDs.contains(ELM327.speedPID)
        let core: [UInt8] = hasSpeed ? [ELM327.rpmPID, ELM327.speedPID] : [ELM327.rpmPID]
        var groups: [[UInt8]] = combineRequests ? [core] : core.map { [$0] }
        if let demandPID { groups.append([demandPID]) }
        if gearFromECU { groups.append([ELM327.gearPID]) }
        return groups
    }

    private func makeSample(_ values: [UInt8: [UInt8]], rpmData: [UInt8]) -> OBDSample {
        var demand: Double?
        if let pid = demandPID, let data = values[pid] {
            let percent = ELM327.percent(data)
            demand = pid == ELM327.pedalPID ? scaledPedal(percent) : percent
        }
        return OBDSample(time: Date(),
                         rpm: ELM327.rpm(rpmData),
                         speed: values[ELM327.speedPID].map { Double($0[0]) },
                         demand: demand,
                         gear: values[ELM327.gearPID].flatMap { ELM327.gear($0) })
    }

    /// PID 49 is the raw pedal sensor: roughly 15 % released and 80 % floored. Scaled to 0–100 %
    /// between the lowest value seen (released) and the highest. Unknown until the pedal has been
    /// seen released.
    private func scaledPedal(_ raw: Double) -> Double? {
        if raw < 30 { pedalReleased = min(pedalReleased ?? raw, raw) }
        pedalFloored = max(pedalFloored, raw)
        guard let released = pedalReleased else { return nil }
        let span = max(pedalFloored - released, 1)
        return min(max((raw - released) / span * 100, 0), 100)
    }

    // MARK: Commands

    /// A mode 01 request; asked again without the reply count if the adapter doesn't take it.
    private func request(_ pids: [UInt8], timeout: TimeInterval = AppConfig.OBD.replyTimeout) async -> String? {
        let reply = await send(ELM327.request(pids, replyCount: useReplyCount), timeout: timeout)
        guard let reply, useReplyCount, ELM327.isUnknownCommand(reply) else { return reply }
        useReplyCount = false
        logLine("OBD: adapter doesn't take a reply count, asking without it")
        return await send(ELM327.request(pids, replyCount: false), timeout: timeout)
    }

    /// Sends one command and waits for the ">" prompt. nil on timeout or when not connected.
    private func send(_ command: String, timeout: TimeInterval = AppConfig.OBD.replyTimeout) async -> String? {
        guard let adapter, let writeChar, pendingReply == nil, !Task.isCancelled else { return nil }
        received = ""
        replyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finishReply(nil)
        }
        return await withCheckedContinuation { continuation in
            pendingReply = continuation
            adapter.writeValue(Data((command + "\r").utf8), for: writeChar, type: .withoutResponse)
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
        writeChar = nil
        received = ""
        isReady = false
        setSample(nil)
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
        guard let end = received.firstIndex(of: ELM327.prompt) else {
            if received.count > 1024 { received = "" }    // never a prompt: don't grow forever
            return
        }
        let reply = String(received[..<end])
        received = ""
        finishReply(reply)
    }
}
