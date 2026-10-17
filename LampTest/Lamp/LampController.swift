// LampController.swift
// Connects to the lamp over BLE and sends commands one at a time.
// Packet builders live in LampProtocol.swift.

import Combine
import CoreBluetooth
import SwiftUI

// MARK: - BLE controller

final class LampController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Waiting for Bluetooth…"
    @Published var isReady = false
    @Published var log: [String] = []
    @Published var appliedState: LampState?    // what was last sent to the lamp

    private var desiredState: LampState = .purpleSteady

    private var central: CBCentralManager!
    private var lamp: CBPeripheral?
    private var writeChar: CBCharacteristic?

    // Current mode state from the lamp. The original app reads this and keeps
    // rhythm sensitivity / mode1 / speed when it changes the mode (copyAndUpdateModeSetup).
    private var modeByte1: UInt8 = 0     // (rhythmSensitivity << 4) | mode1
    private var modeSpeed: UInt8 = 1     // ColorModelCmd default when no state is known

    // Commands are sent one at a time, like the original app (it waits for the reply).
    // Each item builds its packet at send time, so a mode command uses the state
    // the lamp reported just before it (like the original app's copyAndUpdateModeSetup).
    private var queue: [() -> Data] = []
    private var waiting = false
    private var timeout: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Automatic state

    /// Called by the speed logic. Sends commands only when the state actually changes,
    /// and re-applies the state after every (re)connect.
    func setDesired(_ state: LampState) {
        desiredState = state
        applyIfNeeded()
    }

    private func applyIfNeeded() {
        guard isReady, appliedState != desiredState else { return }
        appliedState = desiredState
        addLog("Apply: \(desiredState.label)")
        switch desiredState {
        case .purpleSteady: purpleSteady()
        case .redBreathing: redBreathing()
        }
    }

    // MARK: Lamp commands

    /// Red gradient breathing, done by the lamp firmware.
    /// Same as tapping Breathe -> "Red" (red gradient) in the original app:
    /// SetupViewModel.sendModeCmd -> ColorModelCmd.copyAndUpdateModeSetup(mode2 = 2, modeParam = 1)
    /// It sends only this one mode packet (no color packet). modeParam 0 would be the colorful gradient.
    func redBreathing() {
        enqueueLazy([
            { LampProtocol.query(0x02) },   // read current rhythm/mode1/speed first
            { [unowned self] in LampProtocol.setMode(byte1: self.modeByte1, mode2: 2, param: 1, speed: self.modeSpeed) },
            { LampProtocol.query(0x02) }    // read back what the lamp now reports
        ])
    }

    /// Purple steady: monocolor mode, purple, Zone 1 = 50, Zone 2 = 100
    func purpleSteady() {
        enqueueLazy([
            { LampProtocol.query(0x02) },
            { [unowned self] in LampProtocol.setMode(byte1: self.modeByte1, mode2: 0, param: 0, speed: self.modeSpeed) },
            { LampProtocol.setColor(0x80, 0x00, 0xFF) },
            { LampProtocol.zoneBrightness(zone1: 50, zone2: 100) }
        ])
    }

    // MARK: Send queue

    private func enqueue(_ packets: [Data]) {
        enqueueLazy(packets.map { d -> () -> Data in { d } })
    }

    private func enqueueLazy(_ builders: [() -> Data]) {
        queue += builders
        pump()
    }

    private func pump() {
        guard !waiting, !queue.isEmpty, let p = lamp, let c = writeChar else { return }
        let next = queue.removeFirst()()
        waiting = true
        p.writeValue(next, for: c, type: .withoutResponse)
        addLog("→ \(LampProtocol.hex(next))")

        let work = DispatchWorkItem { [weak self] in
            self?.waiting = false
            self?.pump()
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func replyReceived() {
        timeout?.cancel()
        waiting = false
        pump()
    }

    func addLog(_ s: String) {
        log.append(s)
        if log.count > 40 { log.removeFirst(log.count - 40) }
        print(s)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            status = "Bluetooth is off or not authorized"
            return
        }
        startScan()
    }

    private func startScan() {
        status = "Scanning for Pocket Link…"
        isReady = false
        // The lamp advertises AF30 (not AE30), so match it by name
        central.scanForPeripherals(withServices: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.hasPrefix("Pocket Link") else { return }
        c.stopScan()
        lamp = p
        p.delegate = self
        status = "Connecting to \(name)…"
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Discovering services…"
        p.discoverServices([LampProtocol.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        startScan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        writeChar = nil
        appliedState = nil
        queue.removeAll()
        waiting = false
        startScan()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == LampProtocol.service }) else {
            status = "Service AE30 not found"
            return
        }
        p.discoverCharacteristics([LampProtocol.writeChar, LampProtocol.notifyChar], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == LampProtocol.writeChar { writeChar = c }
            if c.uuid == LampProtocol.notifyChar { p.setNotifyValue(true, for: c) }
        }
        // Same sequence as the original app: wait 500 ms, send StartCmd, then read current mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.enqueue([LampProtocol.start(), LampProtocol.query(0x02)])
            self.status = "Connected: \(p.name ?? "lamp")"
            self.isReady = true
            self.appliedState = nil
            self.applyIfNeeded()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value, !v.isEmpty else { return }
        let b = [UInt8](v)
        addLog("← \(LampProtocol.hex(v))")

        // Mode state reply: 2E 7C len 02 byte1 mode2 param speed cs
        if b.count >= 9, b[0] == 0x2E, b[1] == 0x7C, b[3] == 0x02 {
            modeByte1 = b[4] & 0x7F
            modeSpeed = b[7]
            let names: [UInt8: String] = [0: "steady", 1: "auto", 2: "breathe", 3: "strobe"]
            let gradients = ["colorful", "red", "yellow", "green", "cyan", "blue", "purple"]
            let mode = names[b[5]] ?? "mode \(b[5])"
            let param = (b[5] == 2 && Int(b[6]) < gradients.count) ? gradients[Int(b[6])] : "\(b[6])"
            addLog("   lamp mode: \(mode), param: \(param), speed: \(b[7])")
        }
        replyReceived()
    }
}
