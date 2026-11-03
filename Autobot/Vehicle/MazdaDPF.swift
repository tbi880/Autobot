// MazdaDPF.swift
// The diesel particulate filter (DPF) values of the SkyActiv-D 2.2 engine ECU (PCM, 7E0) and how to
// read them. All are UDS service-22 reads ("22<DID>" -> "62<DID><data…>"); F4xx are the standard
// SAE J1979 mode 01 PIDs mirrored as DIDs (F47A = PID 7A).
//
//   Mazda DIDs (names as Mazda's dealer tool / FORScan show them)
//   042B  PM_ACC_DSD  soot load the PCM regenerates on, g/L — the main gauge
//   042C  PM_ACC      soot accumulated, estimated from the DPF differential pressure, g/L
//   042D  PM_GEN      soot generated since the last regeneration (modelled), g/L
//   0380  REG_REQ_A   automatic regeneration request, byte A bit 0: a request rather than "running" (it
//                     drops to 0 while stopped although the regeneration carries on: see DPFRegenLog)
//   0432  REG_CNT     regenerations so far (community: goes up as one starts, count − 1 = completed; the
//                     data recorder's events show the order on this car)
//   0434  REG_DIS     distance since the last completed regeneration, (B·65536+C·256+D)·100/65536 km
//   03E1  OIL_DIL     fuel in the oil (calculated) — scaling unproven, shown raw     (low confidence)
//   0435              oil-dilution events                                           (low confidence)
//   DD01  TOTAL_DIST  odometer, km
//
//   Standard PIDs (byte A = which fields are supported)
//   F47A  DPF pressures: differential (the back pressure), inlet, outlet, 0.01 kPa
//   F478  exhaust gas temperatures, bank 1 sensors 1–4
//   F47C  DPF inlet / outlet temperature
//   F473  exhaust pressure (upstream, EXHPRES1), 0.01 kPa
//   F469  EGR valves A (hot) / B (cooled): commanded and actual, % — 0 % during a regeneration
//   F411  intake shutter valve position, %
//   F470  boost: target and actual, kPa absolute
//   F477  charge air temperatures, °C
//   F466  mass air flow, g/s
//   F45C  engine oil temperature, °C
//   F405  coolant temperature, °C
//   F48B  diesel aftertreatment status: regeneration running / active vs passive, trigger %, average
//         time and distance between regenerations (not confirmed on the 2015 KE: shows "not answered")
//
// The Mazda DIDs and their scaling come from community reverse engineering (the Torque plugin for
// SKYACTIV-D, FORScan forum users on CX-5 / Mazda6 2.2), not from Mazda documentation; see README,
// "DPF monitor". A value the PCM refuses is simply not asked again while the screen is open, and the
// raw bytes are kept next to every decoded value so the scaling can be checked against FORScan.
// RPM comes from the ordinary mode 01 PID 0C (OBDAdapter.readRPM).

import Foundation

nonisolated enum MazdaDPF {

    /// The engine ECU (PCM): every DPF value lives there.
    static let header = "7E0"

    /// 220380 byte A: the bit that says an automatic regeneration is requested / running (bit 0 on
    /// SkyActiv-D PCMs per the community lists; the raw byte is on the DPF screen to check it).
    static let regenStatusMask: UInt8 = 0x01

    /// One value read from the PCM.
    nonisolated enum Value: String, CaseIterable, Identifiable {
        case sootDesired = "042B"
        case soot = "042C"
        case sootGenerated = "042D"
        case regenStatus = "0380"
        case regenCount = "0432"
        case regenDistance = "0434"
        case pressure = "F47A"
        case exhaustTemps = "F478"
        case dpfTemps = "F47C"
        case exhaustPressure = "F473"
        case egr = "F469"
        case intakeShutter = "F411"
        case boost = "F470"
        case chargeAir = "F477"
        case airFlow = "F466"
        case oilTemp = "F45C"
        case coolant = "F405"
        case aftertreatment = "F48B"
        case oilDilution = "03E1"
        case oilDilutionEvents = "0435"
        case odometer = "DD01"

        var id: String { rawValue }
        var did: String { rawValue }

        var label: String {
            switch self {
            case .sootDesired: return "Soot load (PM_ACC_DSD)"
            case .soot: return "Soot accumulated (PM_ACC)"
            case .sootGenerated: return "Soot generated (PM_GEN)"
            case .regenStatus: return "Regeneration flag"
            case .regenCount: return "Regenerations"
            case .regenDistance: return "Since last regeneration"
            case .pressure: return "DPF pressure"
            case .exhaustTemps: return "Exhaust gas temperatures"
            case .dpfTemps: return "DPF temperatures"
            case .exhaustPressure: return "Exhaust pressure"
            case .egr: return "EGR valves"
            case .intakeShutter: return "Intake shutter"
            case .boost: return "Boost"
            case .chargeAir: return "Charge air temperature"
            case .airFlow: return "Air flow"
            case .oilTemp: return "Oil temperature"
            case .coolant: return "Coolant"
            case .aftertreatment: return "Aftertreatment status"
            case .oilDilution: return "Oil dilution"
            case .oilDilutionEvents: return "Oil dilution events"
            case .odometer: return "Odometer"
            }
        }

        /// Replies longer than one CAN frame (more than 4 data bytes) are read to the end.
        var isMultiFrame: Bool {
            switch self {
            case .pressure, .exhaustTemps, .dpfTemps, .exhaustPressure, .egr, .boost, .chargeAir,
                 .airFlow, .aftertreatment:
                return true
            default:
                return false
            }
        }

        /// Bytes needed to decode it; a shorter reply counts as not answered.
        var minimumLength: Int {
            switch self {
            case .regenStatus, .intakeShutter, .oilTemp, .coolant, .oilDilutionEvents: return 1
            case .sootDesired, .soot, .sootGenerated, .regenCount, .oilDilution: return 2
            case .pressure, .exhaustTemps, .dpfTemps, .exhaustPressure, .egr, .chargeAir,
                 .airFlow, .odometer:
                return 3
            case .regenDistance: return 4
            case .boost: return 5
            case .aftertreatment: return 2
            }
        }
    }

    // MARK: Decoding

    /// DPF pressures from F47A (PID 7A), kPa. Byte 0 says which are reported (bit 0 differential,
    /// bit 1 inlet, bit 2 outlet); a PCM that leaves all three bits clear still gets its differential
    /// pressure read, as the Torque PID does. The differential pressure is signed.
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
        if bits & 0x02 != 0, data.count >= 5 { result.inlet = unsigned16(data[3], data[4]) / 100 }
        if bits & 0x04 != 0, data.count >= 7 { result.outlet = unsigned16(data[5], data[6]) / 100 }
        return result.differential == nil && result.inlet == nil && result.outlet == nil ? nil : result
    }

    /// Soot (042B, 042C, 042D): (256·A + B) · 100 / 65536 g/L.
    static func soot(_ data: [UInt8]) -> Double? {
        guard data.count >= 2 else { return nil }
        return unsigned16(data[0], data[1]) * 100 / 65536
    }

    /// Regeneration request / active (0380): byte A, regenStatusMask (bit 0).
    static func regenerating(_ data: [UInt8]) -> Bool? {
        guard let first = data.first else { return nil }
        return first & regenStatusMask != 0
    }

    /// Regenerations so far (0432): 256·A + B.
    static func regenCount(_ data: [UInt8]) -> Int? {
        guard data.count >= 2 else { return nil }
        return Int(data[0]) * 256 + Int(data[1])
    }

    /// Distance since the last regeneration (0434): (B·65536 + C·256 + D) · 100 / 65536 km; A unused.
    static func regenDistance(_ data: [UInt8]) -> Double? {
        guard data.count >= 4 else { return nil }
        return Double(Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])) * 100 / 65536
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

    /// Exhaust pressure bank 1 (F473, PID 73), kPa: byte 0 bit 0, then (256·B + C) / 100.
    static func exhaustPressure(_ data: [UInt8]) -> Double? {
        guard data.count >= 3, data[0] & 0x01 != 0 || data[0] == 0 else { return nil }
        return unsigned16(data[1], data[2]) / 100
    }

    /// EGR (F469, PID 69): valve A commanded B, actual C; valve B commanded E, actual F; % = raw / 2.55.
    /// Byte 0 bits: 0 A commanded, 1 A actual, 3 B commanded, 4 B actual.
    nonisolated struct EGR: Equatable {
        var commandedA: Double?
        var actualA: Double?
        var commandedB: Double?
        var actualB: Double?
    }

    static func egr(_ data: [UInt8]) -> EGR? {
        guard let bits = data.first, data.count >= 3 else { return nil }
        func pct(_ i: Int, _ bit: UInt8) -> Double? {
            bits & bit != 0 && i < data.count ? Double(data[i]) * 100 / 255 : nil
        }
        let result = EGR(commandedA: pct(1, 0x01), actualA: pct(2, 0x02), commandedB: pct(4, 0x08), actualB: pct(5, 0x10))
        return result == EGR() ? nil : result
    }

    /// Intake shutter valve (F411, PID 11): A · 100 / 255 %.
    static func intakeShutter(_ data: [UInt8]) -> Double? {
        data.first.map { Double($0) * 100 / 255 }
    }

    /// Boost (F470, PID 70): target (256·B + C) / 32, actual (256·D + E) / 32 kPa absolute; byte 0 bit 0
    /// target, bit 1 actual.
    static func boost(_ data: [UInt8]) -> (target: Double?, actual: Double?) {
        guard let bits = data.first, data.count >= 5 else { return (nil, nil) }
        let target: Double? = bits & 0x01 != 0 ? unsigned16(data[1], data[2]) / 32 : nil
        let actual: Double? = bits & 0x02 != 0 ? unsigned16(data[3], data[4]) / 32 : nil
        return (target, actual)
    }

    /// Charge air temperatures (F477, PID 77), °C by sensor 1–2 (bank 1): byte 0 bit 0 = B, bit 1 = C,
    /// A − 40 each.
    static func chargeAir(_ data: [UInt8]) -> [Int: Double] {
        guard let bits = data.first else { return [:] }
        var temps: [Int: Double] = [:]
        for sensor in 1...2 where bits & (1 << UInt8(sensor - 1)) != 0 && sensor < data.count {
            temps[sensor] = Double(data[sensor]) - 40
        }
        return temps
    }

    /// Mass air flow (F466, PID 66), sensor A: (256·B + C) / 32 g/s.
    static func airFlow(_ data: [UInt8]) -> Double? {
        guard data.count >= 3, data[0] & 0x01 != 0 || data[0] == 0 else { return nil }
        return unsigned16(data[1], data[2]) / 32
    }

    /// Engine oil / coolant temperature (F45C, F405): A − 40 °C.
    static func celsius(_ data: [UInt8]) -> Double? {
        data.first.map { Double($0) - 40 }
    }

    /// Diesel aftertreatment status (F48B, PID 8B). Byte 0 says which fields are reported; byte 1
    /// bit 0 = regeneration running, bit 1 = active (1) / passive (0); byte 2 = trigger, raw·100/255 %;
    /// bytes 3–4 = average minutes and 5–6 = average km between regenerations.
    nonisolated struct Aftertreatment: Equatable {
        var regenerating: Bool?
        var active: Bool?
        var triggerPercent: Double?
        var averageMinutes: Double?
        var averageKm: Double?
    }

    static func aftertreatment(_ data: [UInt8]) -> Aftertreatment? {
        guard data.count >= 2 else { return nil }
        let bits = data[0]
        var result = Aftertreatment()
        if bits & 0x01 != 0 { result.regenerating = data[1] & 0x01 != 0 }
        if bits & 0x02 != 0 { result.active = data[1] & 0x02 != 0 }
        if bits & 0x04 != 0, data.count >= 3 { result.triggerPercent = Double(data[2]) * 100 / 255 }
        if bits & 0x08 != 0, data.count >= 5 { result.averageMinutes = unsigned16(data[3], data[4]) }
        if bits & 0x10 != 0, data.count >= 7 { result.averageKm = unsigned16(data[5], data[6]) }
        return result == Aftertreatment() ? nil : result
    }

    /// 2-byte value as it is (03E1 oil dilution: unit unproven).
    static func word(_ data: [UInt8]) -> Double? {
        guard data.count >= 2 else { return nil }
        return unsigned16(data[0], data[1])
    }

    /// Odometer (DD01): 65536·A + 256·B + C km.
    static func odometer(_ data: [UInt8]) -> Double? {
        guard data.count >= 3 else { return nil }
        return Double(Int(data[0]) << 16 | Int(data[1]) << 8 | Int(data[2]))
    }

    // MARK: Helpers

    private static func signed16(_ high: UInt8, _ low: UInt8) -> Double {
        Double(Int16(bitPattern: UInt16(high) << 8 | UInt16(low)))
    }

    private static func unsigned16(_ high: UInt8, _ low: UInt8) -> Double {
        Double(Int(high) * 256 + Int(low))
    }

    private static func temperature(_ high: UInt8, _ low: UInt8) -> Double {
        unsigned16(high, low) / 10 - 40
    }
}

/// Everything the DPF monitor knows right now. nil = not read yet, or the PCM doesn't answer it.
nonisolated struct DPFReading: Equatable {
    var rpm: Double?
    var sootDesired: Double?
    var soot: Double?
    var sootGenerated: Double?
    var regenerating: Bool?
    var regenCount: Int?
    var regenDistance: Double?
    var pressure: MazdaDPF.Pressure?
    var exhaustTemps: [Int: Double] = [:]
    var dpfInletTemp: Double?
    var dpfOutletTemp: Double?
    var exhaustPressure: Double?
    var egr: MazdaDPF.EGR?
    var intakeShutter: Double?
    var boostTarget: Double?
    var boost: Double?
    var chargeAirTemps: [Int: Double] = [:]
    var airFlow: Double?
    var oilTemp: Double?
    var coolant: Double?
    var aftertreatment: MazdaDPF.Aftertreatment?
    var oilDilution: Double?
    var oilDilutionEvents: Int?
    var odometer: Double?
    /// The last raw data bytes of every value, by DID, for checking the scaling.
    var raw: [String: [UInt8]] = [:]

    /// Fills in one value from its raw data bytes. False if the bytes couldn't be decoded.
    @discardableResult
    mutating func apply(_ value: MazdaDPF.Value, data: [UInt8]) -> Bool {
        guard data.count >= value.minimumLength else { return false }
        raw[value.did] = data
        switch value {
        case .sootDesired: sootDesired = MazdaDPF.soot(data)
        case .soot: soot = MazdaDPF.soot(data)
        case .sootGenerated: sootGenerated = MazdaDPF.soot(data)
        case .regenStatus: regenerating = MazdaDPF.regenerating(data)
        case .regenCount: regenCount = MazdaDPF.regenCount(data)
        case .regenDistance: regenDistance = MazdaDPF.regenDistance(data)
        case .pressure:
            guard let decoded = MazdaDPF.pressure(data) else { return false }
            pressure = decoded
        case .exhaustTemps: exhaustTemps = MazdaDPF.exhaustTemps(data)
        case .dpfTemps:
            let temps = MazdaDPF.dpfTemps(data)
            dpfInletTemp = temps.inlet
            dpfOutletTemp = temps.outlet
        case .exhaustPressure: exhaustPressure = MazdaDPF.exhaustPressure(data)
        case .egr: egr = MazdaDPF.egr(data)
        case .intakeShutter: intakeShutter = MazdaDPF.intakeShutter(data)
        case .boost:
            let b = MazdaDPF.boost(data)
            boostTarget = b.target
            boost = b.actual
        case .chargeAir: chargeAirTemps = MazdaDPF.chargeAir(data)
        case .airFlow: airFlow = MazdaDPF.airFlow(data)
        case .oilTemp: oilTemp = MazdaDPF.celsius(data)
        case .coolant: coolant = MazdaDPF.celsius(data)
        case .aftertreatment: aftertreatment = MazdaDPF.aftertreatment(data)
        case .oilDilution: oilDilution = MazdaDPF.word(data)
        case .oilDilutionEvents: oilDilutionEvents = data.first.map(Int.init)
        case .odometer: odometer = MazdaDPF.odometer(data)
        }
        return true
    }

    /// The soot figure for gauges and thresholds: PM_ACC_DSD (what the PCM regenerates on), else PM_ACC.
    var sootLoad: Double? { sootDesired ?? soot }

    /// The hottest exhaust / DPF temperature reported, °C.
    var hottestExhaust: Double? {
        (Array(exhaustTemps.values) + [dpfInletTemp, dpfOutletTemp].compactMap { $0 }).max()
    }
}
