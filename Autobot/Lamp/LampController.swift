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

    // The packet currently waiting for a reply, so it can be resent after a "busy" answer.
    private var inFlight: (() -> Data)?
    private var nackRetries = 0

    /// After a mode command, the lamp's next mode report must match; otherwise the command is resent.
    private struct ModeCheck {
        let mode2: UInt8
        let param: UInt8?            // nil = don't check the parameter
        let attempt: [() -> Data]    // the packets to resend
        var retriesLeft: Int
        var armed = false            // becomes true once the mode command has been sent
    }
    private var modeCheck: ModeCheck?

    /// Turns on Bluetooth and starts looking for the lamp. Called when ENGINE START is pressed.
    func start() {
        if AppConfig.TestMode.enabled {
            status = "Connected: simulated lamp"
            isReady = true
            return
        }
        guard central == nil else { return }
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
        case .redBurstFlash: redBurstFlash()
        case .blueBurstFlash: blueBurstFlash()
        case .yellowBurstFlash: yellowBurstFlash()
        case .yellowBreathing: yellowBreathing()
        case .cyanBreathing: cyanBreathing()
        }
    }

    // MARK: Lamp commands

    /// Red gradient breathing, done by the lamp firmware.
    /// Same as tapping Breathe -> "Red" (red gradient) in the original app:
    /// SetupViewModel.sendModeCmd -> ColorModelCmd.copyAndUpdateModeSetup(mode2 = 2, modeParam = 1)
    /// modeParam 0 would be the colorful gradient, 6 the purple one.
    func redBreathing() {
        breathing(gradient: 1, red: 0xFF, green: 0x00, blue: 0x00)
    }

    /// Yellow gradient breathing, while reversing (ReverseLight): Breathe -> "Yellow Gradient" (黄色渐变)
    /// in the original app, ColorModelCmd.copyAndUpdateModeSetup(mode2 = 2, modeParam = 2), i.e.
    /// 2E 8D 05 02 [rhythm<<4 | mode1] 02 02 [speed] cs. The breathing list
    /// (ColorModeItem.modeParamBreatheGradient): 0 colourful, 1 red, 2 yellow, 3 green, 4 cyan, 5 blue,
    /// 6 purple.
    func yellowBreathing() {
        breathing(gradient: 2, red: 0xFF, green: 0xFF, blue: 0x00)
    }

    /// Cyan gradient breathing, rain mode (RainMode): Breathe -> "Cyan Gradient" (青色渐变) in the
    /// original app, gradient 4 of the list above: 2E 8D 05 02 [rhythm<<4 | mode1] 02 04 [speed] cs.
    func cyanBreathing() {
        breathing(gradient: 4, red: 0x00, green: 0xFF, blue: 0xFF)
    }

    /// Firmware breathing with one of the gradients above, the custom colour set to the same colour
    /// first (AppConfig.Lamp.setColourBeforeBreathing).
    private func breathing(gradient: UInt8, red: UInt8, green: UInt8, blue: UInt8) {
        let prepare: [() -> Data] = AppConfig.Lamp.setColourBeforeBreathing
            ? [{ LampProtocol.setColor(red, green, blue) }]
            : []
        setModeVerified(mode2: 2, param: gradient, prepare: prepare)
    }

    /// Red Burst Flash (single-colour strobe), done by the lamp firmware.
    /// Original app: mode list "Burst Flash" = mode2 3, parameter list "Red Burst Flash" = 1
    /// (0 would be the multicolour flash). Brightness is left unchanged so restoring is exact.
    func redBurstFlash() {
        setModeVerified(mode2: 3, param: 1, prepare: [{ LampProtocol.setColor(0xFF, 0x00, 0x00) }])
    }

    /// Blue Burst Flash: the same firmware strobe with parameter 5 ("Blue Burst Flash" / 蓝色爆闪 in
    /// the original app's list ColorModeItem.modeParamStrobe: 0 colourful, 1 red, 2 yellow, 3 green,
    /// 4 cyan, 5 blue, 6 purple, 7 white). The custom colour is set to blue first, like red above.
    func blueBurstFlash() {
        setModeVerified(mode2: 3, param: 5, prepare: [{ LampProtocol.setColor(0x00, 0x00, 0xFF) }])
    }

    /// Yellow Burst Flash, while the turn signals or the hazard lights flash (TurnSignalFlash): the
    /// same firmware strobe with parameter 2 ("Yellow Burst Flash" / 黄色爆闪 in the original app's
    /// ColorModeItem.modeParamStrobe), i.e. 2E 8D 05 02 [rhythm<<4 | mode1] 03 02 [speed] cs.
    /// The custom colour is set to yellow first (2E 8D 08 01 08 FF FF 00 FF FF 00 65), like red and
    /// blue above.
    func yellowBurstFlash() {
        setModeVerified(mode2: 3, param: 2, prepare: [{ LampProtocol.setColor(0xFF, 0xFF, 0x00) }])
    }

    /// Purple steady: monocolor mode, purple, Zone 1 = 50, Zone 2 = 100
    func purpleSteady() {
        setModeVerified(mode2: 0, param: nil, prepare: [])
        enqueueLazy([
            { LampProtocol.setColor(0x80, 0x00, 0xFF) },
            { LampProtocol.zoneBrightness(zone1: 50, zone2: 100) }
        ])
    }

    /// Reads the current mode, sends the new one, reads it back and resends if the lamp
    /// reports something else (see checkModeReport).
    private func setModeVerified(mode2: UInt8, param: UInt8?, prepare: [() -> Data]) {
        let attempt: [() -> Data] = prepare + [
            { [unowned self] in
                self.modeCheck?.armed = true
                return LampProtocol.setMode(byte1: self.modeByte1, mode2: mode2,
                                            param: param ?? 0, speed: self.modeSpeed)
            },
            { LampProtocol.query(0x02) },   // read back
        ]
        modeCheck = ModeCheck(mode2: mode2, param: param, attempt: attempt,
                              retriesLeft: AppConfig.Lamp.modeRetries)
        enqueueLazy([{ LampProtocol.query(0x02) }] + attempt)   // current rhythm/mode1/speed first
    }

    private func checkModeReport(mode2: UInt8, param: UInt8) {
        guard var check = modeCheck, check.armed else { return }
        if mode2 == check.mode2, check.param == nil || check.param == param {
            addLog("   ✓ lamp confirmed the mode")
            modeCheck = nil
            return
        }
        guard check.retriesLeft > 0 else {
            addLog("   ✗ lamp still reports a different mode, giving up")
            modeCheck = nil
            return
        }
        check.retriesLeft -= 1
        check.armed = false
        modeCheck = check
        addLog("   ✗ lamp reports a different mode, resending (\(check.retriesLeft) retries left)")
        queue.insert(contentsOf: check.attempt, at: 0)
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
        let builder = queue.removeFirst()
        inFlight = builder
        let next = builder()
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
        modeCheck = nil
        inFlight = nil
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

        // "Busy" (FC) or "checksum error" (F0): resend the same packet shortly
        if b.count == 1, b[0] == 0xFC || b[0] == 0xF0,
           let retry = inFlight, nackRetries < AppConfig.Lamp.nackRetries {
            nackRetries += 1
            addLog("   lamp busy / checksum error, resending")
            timeout?.cancel()
            queue.insert(retry, at: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.waiting = false
                self?.pump()
            }
            return
        }
        nackRetries = 0

        // Mode state reply: 2E 7C len 02 byte1 mode2 param speed cs
        if b.count >= 9, b[0] == 0x2E, b[1] == 0x7C, b[3] == 0x02 {
            modeByte1 = b[4] & 0x7F
            modeSpeed = b[7]
            let names: [UInt8: String] = [0: "steady", 1: "auto", 2: "breathe", 3: "strobe"]
            // Breathing (2) and burst flash (3) share one colour list (breathing stops at purple).
            let colours = ["colorful", "red", "yellow", "green", "cyan", "blue", "purple", "white"]
            let mode = names[b[5]] ?? "mode \(b[5])"
            let param = ((b[5] == 2 || b[5] == 3) && Int(b[6]) < colours.count) ? colours[Int(b[6])] : "\(b[6])"
            addLog("   lamp mode: \(mode), param: \(param), speed: \(b[7])")
            checkModeReport(mode2: b[5], param: b[6])
        }
        replyReceived()
    }
}
