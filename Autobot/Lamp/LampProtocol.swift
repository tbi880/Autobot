// LampProtocol.swift
// BLE packet format reverse-engineered from LAMP&FRGN 1.2.7 (com.szraise.carled).
//
// Frame:  2E | type | len | data[len] | checksum
// checksum = (type + len + all data bytes) XOR 0xFF, low 8 bits only
// Write -> service AE30 / characteristic AE01 (write without response)
// Reply <- service AE30 / characteristic AE02 (notify)

import CoreBluetooth

// MARK: - Packet builders (direct copies of the original app's pack() methods)

enum LampProtocol {
    static let service    = CBUUID(string: "AE30")
    static let writeChar  = CBUUID(string: "AE01")
    static let notifyChar = CBUUID(string: "AE02")

    /// DataPack.Companion.pack(dataType, datas...)
    static func pack(_ type: UInt8, _ data: [UInt8]) -> Data {
        let body = [type, UInt8(data.count)] + data
        let sum = body.reduce(0) { ($0 + Int($1)) & 0xFF }
        return Data([0x2E] + body + [UInt8((sum ^ 0xFF) & 0xFF)])
    }

    /// StartCmd -> 2E 81 01 01 7C (sent 500 ms after connecting)
    static func start() -> Data { pack(0x81, [0x01]) }

    /// ColorControlCmd(setup=true, type=0 uniform) -> 2E 8D 08 01 08 R G B R G B cs
    static func setColor(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Data {
        pack(0x8D, [0x01, 0x08, r, g, b, r, g, b])
    }

    /// ColorModelCmd(setup=true) -> 2E 8D 05 02 [rhythm<<4 | mode1] mode2 modeParam modeSpeed cs
    /// mode2: 0 = monocolor (steady), 1 = auto, 2 = breathe, 3 = strobe, 4/5 = rhythm
    /// modeParam for breathe: 0 multicolor, 1 red, 2 yellow, 3 green, 4 cyan, 5 blue, 6 purple
    /// modeParam for strobe ("Burst Flash"): the same list plus 7 white (ColorModeItem.modeParamStrobe)
    static func setMode(byte1: UInt8, mode2: UInt8, param: UInt8, speed: UInt8) -> Data {
        pack(0x8D, [0x02, byte1, mode2, param, speed])
    }

    /// BrightnessCmd(setup=true, type=0 two zones) -> 2E 8D 04 00 [0x40 if on] zone1 zone2 cs
    /// Brightness range 0...100. Same packet the original app sends from its Zone 1 / Zone 2 sliders.
    static func zoneBrightness(on: Bool = true, zone1: UInt8, zone2: UInt8) -> Data {
        pack(0x8D, [0x00, on ? 0x40 : 0x00, min(zone1, 100), min(zone2, 100)])
    }

    /// Queries: 2E 90 02 7C <sub>  (sub 0 = brightness, 1 = color, 2 = mode)
    static func query(_ sub: UInt8) -> Data { pack(0x90, [0x7C, sub]) }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
