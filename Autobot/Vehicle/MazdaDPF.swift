// MazdaDPF.swift
// The diesel particulate filter (DPF) values of the SkyActiv-D 2.2 engine ECU (PCM, 7E0) and how to
// read them. All are UDS service-22 reads ("22<DID>" -> "62<DID><data…>").
//
//   F47A  DPF pressure (SAE J1979 PID 7A, mirrored as DID F4xx): bits of what's supported, then
//         differential (inlet − outlet), inlet and outlet pressure, signed 0.01 kPa each.
//         The differential pressure is the DPF back pressure.
//   042C  soot (particulate matter) accumulated in the DPF, g/L
//   042D  soot generated since the last regeneration, g/L (resets at a regeneration)
//   0380  regeneration status, bit 1 of the first byte
//   0432  regenerations so far (count)
//   0434  distance since the last regeneration, km
//   F478  exhaust gas temperatures, bank 1 sensors 1–4 (J1979 PID 78)
//   F47C  DPF inlet / outlet temperature (J1979 PID 7C)
//   F405  coolant temperature (J1979 PID 05)
//
// The Mazda-specific DIDs (04xx, 0380) and their scaling come from community Torque PID lists for
// SkyActiv-D cars, not from Mazda documentation; see README, "DPF monitor". The raw bytes are kept
// next to every decoded value so the scaling can be checked against FORScan / a dealer tool.
// RPM comes from the ordinary mode 01 PID 0C (OBDAdapter.readRPM).

import Foundation

nonisolated enum MazdaDPF {

    /// The engine ECU (PCM): every DPF value lives there.
    static let header = "7E0"

    /// One value read from the PCM.
    nonisolated enum Value: String, CaseIterable, Identifiable {
        case pressure = "F47A"
        case soot = "042C"
        case sootGenerated = "042D"
        case regenStatus = "0380"
        case regenCount = "0432"
        case regenDistance = "0434"
        case exhaustTemps = "F478"
        case dpfTemps = "F47C"
        case coolant = "F405"

        var id: String { rawValue }
        var did: String { rawValue }

        var label: String {
            switch self {
            case .pressure: return "DPF pressure"
            case .soot: return "Soot accumulated"
            case .sootGenerated: return "Soot generated"
            case .regenStatus: return "Regeneration status"
            case .regenCount: return "Regenerations"
            case .regenDistance: return "Since last regeneration"
            case .exhaustTemps: return "Exhaust gas temperatures"
            case .dpfTemps: return "DPF temperatures"
            case .coolant: return "Coolant"
            }
        }

        /// Replies longer than one CAN frame (more than 4 data bytes) are read to the end.
        var isMultiFrame: Bool {
            switch self {
            case .pressure, .exhaustTemps, .dpfTemps: return true
            default: return false
            }
        }

        /// Bytes needed to decode it; a shorter reply counts as not answered.
        var minimumLength: Int {
            switch self {
            case .pressure: return 3
            case .soot, .sootGenerated, .regenCount: return 2
            case .regenStatus, .coolant: return 1
            case .regenDistance: return 4
            case .exhaustTemps, .dpfTemps: return 3
            }
        }
    }

    // MARK: Decoding

    /// DPF pressures from F47A (PID 7A), kPa. Byte 0 says which are reported (bit 0 differential,
    /// bit 1 inlet, bit 2 outlet); a PCM that leaves all three bits clear still gets its differential
    /// pressure read, as the Torque PID does.
    nonisolated struct Pressure: Equatable {
        var differential: Double?
        var inlet: Double?
        var outlet: Double?
    }

    static func pressure(_ data: [UInt8]) -> Pressure? {
        guard data.count >= 3 else { return nil }
        let bits = data[0]
        var result = Pressure()
        if bits & 0x01 != 0 || bits & 0x07 == 0 {
            result.differential = signed16(data[1], data[2]) / 100
        }
        if bits & 0x02 != 0, data.count >= 5 { result.inlet = signed16(data[3], data[4]) / 100 }
        if bits & 0x04 != 0, data.count >= 7 { result.outlet = signed16(data[5], data[6]) / 100 }
        return result.differential == nil && result.inlet == nil && result.outlet == nil ? nil : result
    }

    /// Soot in the DPF (042C accumulated, 042D generated): (256·A + B) · 100 / 65536 g/L.
    static func soot(_ data: [UInt8]) -> Double? {
        guard data.count >= 2 else { return nil }
        return Double(Int(data[0]) * 256 + Int(data[1])) * 100 / 65536
    }

    /// Regeneration running (0380): bit 1 of the first byte.
    static func regenerating(_ data: [UInt8]) -> Bool? {
        guard let first = data.first else { return nil }
        return first & 0x02 != 0
    }

    /// Regenerations so far (0432): 256·A + B.
    static func regenCount(_ data: [UInt8]) -> Int? {
        guard data.count >= 2 else { return nil }
        return Int(data[0]) * 256 + Int(data[1])
    }

    /// Distance since the last regeneration (0434): (B·65536 + C·256 + D) / 640 km.
    static func regenDistance(_ data: [UInt8]) -> Double? {
        guard data.count >= 4 else { return nil }
        return Double(Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])) / 640
    }

    /// Exhaust gas temperatures (F478, PID 78), °C by sensor number 1–4: byte 0 says which are
    /// reported (bit 0 = sensor 1 …), then 2 bytes each, raw / 10 − 40.
    static func exhaustTemps(_ data: [UInt8]) -> [Int: Double] {
        guard let bits = data.first else { return [:] }
        var temps: [Int: Double] = [:]
        for sensor in 1...4 where bits & (1 << UInt8(sensor - 1)) != 0 {
            let i = 1 + (sensor - 1) * 2
            guard i + 1 < data.count else { break }
            temps[sensor] = temperature(data[i], data[i + 1])
        }
        return temps
    }

    /// DPF inlet / outlet temperature (F47C, PID 7C), °C: byte 0 bit 0 inlet, bit 1 outlet; then
    /// 2 bytes each, raw / 10 − 40.
    static func dpfTemps(_ data: [UInt8]) -> (inlet: Double?, outlet: Double?) {
        guard let bits = data.first else { return (nil, nil) }
        let inlet: Double? = bits & 0x01 != 0 && data.count >= 3 ? temperature(data[1], data[2]) : nil
        let outlet: Double? = bits & 0x02 != 0 && data.count >= 5 ? temperature(data[3], data[4]) : nil
        return (inlet, outlet)
    }

    /// Coolant temperature (F405, PID 05): A − 40 °C.
    static func coolant(_ data: [UInt8]) -> Double? {
        data.first.map { Double($0) - 40 }
    }

    // MARK: Helpers

    private static func signed16(_ high: UInt8, _ low: UInt8) -> Double {
        Double(Int16(bitPattern: UInt16(high) << 8 | UInt16(low)))
    }

    private static func temperature(_ high: UInt8, _ low: UInt8) -> Double {
        Double(Int(high) * 256 + Int(low)) / 10 - 40
    }
}

/// Everything the DPF monitor knows right now. nil = not read yet, or the PCM doesn't answer it.
nonisolated struct DPFReading: Equatable {
    var rpm: Double?
    var pressure: MazdaDPF.Pressure?
    var soot: Double?
    var sootGenerated: Double?
    var regenerating: Bool?
    var regenCount: Int?
    var regenDistance: Double?
    var exhaustTemps: [Int: Double] = [:]
    var dpfInletTemp: Double?
    var dpfOutletTemp: Double?
    var coolant: Double?
    /// The last raw data bytes of every value, by DID, for checking the scaling.
    var raw: [String: [UInt8]] = [:]

    /// Fills in one value from its raw data bytes. False if the bytes couldn't be decoded.
    @discardableResult
    mutating func apply(_ value: MazdaDPF.Value, data: [UInt8]) -> Bool {
        guard data.count >= value.minimumLength else { return false }
        raw[value.did] = data
        switch value {
        case .pressure:
            guard let decoded = MazdaDPF.pressure(data) else { return false }
            pressure = decoded
        case .soot: soot = MazdaDPF.soot(data)
        case .sootGenerated: sootGenerated = MazdaDPF.soot(data)
        case .regenStatus: regenerating = MazdaDPF.regenerating(data)
        case .regenCount: regenCount = MazdaDPF.regenCount(data)
        case .regenDistance: regenDistance = MazdaDPF.regenDistance(data)
        case .exhaustTemps: exhaustTemps = MazdaDPF.exhaustTemps(data)
        case .dpfTemps:
            let temps = MazdaDPF.dpfTemps(data)
            dpfInletTemp = temps.inlet
            dpfOutletTemp = temps.outlet
        case .coolant: coolant = MazdaDPF.coolant(data)
        }
        return true
    }

    /// The hottest exhaust / DPF temperature reported, °C.
    var hottestExhaust: Double? {
        (Array(exhaustTemps.values) + [dpfInletTemp, dpfOutletTemp].compactMap { $0 }).max()
    }
}
