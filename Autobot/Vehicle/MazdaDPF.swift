// MazdaDPF.swift
// The diesel particulate filter (DPF) values of the SkyActiv-D 2.2 engine ECU (PCM, 7E0) and how to
// read them. All are UDS service-22 reads ("22<DID>" -> "62<DID><data…>"); F4xx are the standard
// SAE J1979 mode 01 PIDs mirrored as DIDs (F47A = PID 7A).
//
//   Mazda DIDs (names as Mazda's dealer tool / FORScan show them; names, bits and scaling checked
//   against FORScan Viewer 1.5.31's PCM definitions for the SKYACTIV-D, Nov 2026)
//   044B  PM_ACC_DSD  PM accumulation amount desired, g/L: the soot figure the PCM decides on. Mazda's
//                     DTC P243C test: at a steady 3,000 rpm, twice PM_GEN or more = DPF pressure sensor
//   042C  PM_ACC      soot accumulated, estimated from the DPF differential pressure, g/L
//   042D  PM_GEN      soot generated since the last regeneration (modelled), g/L — the main gauge
//   042B  FIP_SCV     NOT soot: the fuel pump's suction control valve current, raw/8000 A (recorder only).
//                     Community lists called it PM_ACC_DSD; read as g/L it showed 19–25 and followed load
//   0380  REG_REQ_F / REG_REQ_A  regeneration requests, byte A: bit 0 forced, bit 1 automatic. Requests
//                     rather than "running" (they drop while stopped although the regeneration carries on:
//                     see DPFRegenLog). Bit 1 wasn't checked before Nov 2026, so automatic ones were missed
//   0432  REG_CNT     regenerations so far. On this car it goes up at the END of one: PM_ACC was already
//                     down at 0–1 g/L every time it went up (Autobot's log, regenerations 280–286)
//   0434  REG_DIS     distance since the last completed regeneration: the whole value ·100/64000 km
//   03E1  OIL_DIL     the PCM's estimate of fuel in the oil, (A·256+B)·100000/65535 g (FORScan; Mazda sets
//                     P252F at 1,661 g, P253F at 2,236 g)
//   0435  OIL_DIL_CNT times the PCM judged the oil deteriorated
//   DD01  TOTAL_DIST  odometer as the cluster shows it, km; Autobot adds AppConfig.Odometer.offsetKm
//                     (this car's odometer was adjusted)
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
// SKYACTIV-D, FORScan forum users on CX-5 / Mazda6 2.2) and FORScan's own PCM definitions, not from
// Mazda documentation; see README, "DPF monitor". 0434 follows FORScan since Nov 2026 (the whole value
// ·100/64000); the community ·100/65536 used before read 2.4 % less, and what was saved in it is converted
// once (DPFRegenLog, DPFRecorder). A value the PCM refuses is simply not asked again while the screen is
// open, and the raw bytes are kept next to every decoded value so the scaling can be checked against FORScan.
// RPM comes from the ordinary mode 01 PID 0C (OBDAdapter.readRPM).

import Foundation

nonisolated enum MazdaDPF {

    /// The engine ECU (PCM): every DPF value lives there.
    static let header = "7E0"

    /// 220380 byte A: the regeneration request bits, bit 0 forced (REG_REQ_F) and bit 1 automatic
    /// (REG_REQ_A) per FORScan's PCM definitions; either one counts as a regeneration (the raw byte is on
    /// the DPF screen to check it).
    static let regenStatusMask: UInt8 = 0x03
    static let regenForcedBit: UInt8 = 0x01
    static let regenAutomaticBit: UInt8 = 0x02

    /// 220434 REG_DIS: raw units per 100 km, of the whole 4-byte value (FORScan: ·100/64000, 1/640 km a unit).
    static let regenDistanceUnitsPer100Km = 64_000.0
    /// The scale Autobot used before Nov 2026 (community lists: ·100/65536 of bytes B–D, 2.4 % less), for
    /// converting the distances saved in it.
    static let regenDistanceUnitsPer100KmBefore = 65_536.0

    /// One value read from the PCM.
    nonisolated enum Value: String, CaseIterable, Identifiable {
        case sootDesired = "044B"
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
            case .sootDesired: return "Soot desired (PM_ACC_DSD)"
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
            case .oilDilution: return "Fuel in the oil (PCM estimate)"
            case .oilDilutionEvents: return "Oil judged deteriorated"
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

    /// Soot (044B, 042C, 042D): (256·A + B) · 100 / 65536 g/L (FORScan: / 65535, the same to 0.002 %).
    static func soot(_ data: [UInt8]) -> Double? {
        guard data.count >= 2 else { return nil }
        return unsigned16(data[0], data[1]) * 100 / 65536
    }

    /// Regeneration requested (0380): byte A, either bit of regenStatusMask.
    static func regenerating(_ data: [UInt8]) -> Bool? {
        guard let first = data.first else { return nil }
        return first & regenStatusMask != 0
    }

    /// "forced", "automatic", "forced + automatic", or nil when neither bit is on (0380 byte A).
    static func regenKind(_ data: [UInt8]) -> String? {
        guard let first = data.first else { return nil }
        let forced = first & regenForcedBit != 0
        let automatic = first & regenAutomaticBit != 0
        switch (forced, automatic) {
        case (true, true): return "forced + automatic"
        case (true, false): return "forced"
        case (false, true): return "automatic"
        default: return nil
        }
    }

    /// Regenerations so far (0432): 256·A + B.
    static func regenCount(_ data: [UInt8]) -> Int? {
        guard data.count >= 2 else { return nil }
        return Int(data[0]) * 256 + Int(data[1])
    }

    /// Distance since the last regeneration (0434): the whole value, A·2²⁴ + B·65536 + C·256 + D, · 100 /
    /// 64000 km (FORScan).
    static func regenDistance(_ data: [UInt8]) -> Double? {
        guard data.count >= 4 else { return nil }
        let raw = Int(data[0]) << 24 | Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])
        return Double(raw) * 100 / regenDistanceUnitsPer100Km
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

    /// 2-byte value as it is.
    static func word(_ data: [UInt8]) -> Double? {
        guard data.count >= 2 else { return nil }
        return unsigned16(data[0], data[1])
    }

    /// The PCM's estimate of fuel in the oil (03E1, OIL_DIL): (A·256 + B) · 100000 / 65535 g (FORScan).
    static func oilDilution(_ data: [UInt8]) -> Double? {
        word(data).map { $0 * 100000 / 65535 }
    }

    /// Odometer as the cluster shows it (DD01): 65536·A + 256·B + C km.
    static func odometerShown(_ data: [UInt8]) -> Double? {
        guard data.count >= 3 else { return nil }
        return Double(Int(data[0]) << 16 | Int(data[1]) << 8 | Int(data[2]))
    }

    /// The distance the car has really covered: the odometer (DD01) + AppConfig.Odometer.offsetKm, as this
    /// car's odometer was adjusted. What Autobot shows, logs and records.
    static func odometer(_ data: [UInt8]) -> Double? {
        odometerShown(data).map { $0 + AppConfig.Odometer.offsetKm }
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
    /// The PCM's estimate of fuel in the oil, g.
    var oilDilution: Double?
    var oilDilutionEvents: Int?
    /// The true distance (+ AppConfig.Odometer.offsetKm) and what the cluster shows, km.
    var odometer: Double?
    var odometerShown: Double?
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
        case .oilDilution: oilDilution = MazdaDPF.oilDilution(data)
        case .oilDilutionEvents: oilDilutionEvents = data.first.map(Int.init)
        case .odometer:
            odometer = MazdaDPF.odometer(data)
            odometerShown = MazdaDPF.odometerShown(data)
        }
        return true
    }

    /// The soot figure for gauges and thresholds: PM_GEN (the modelled soot a regeneration starts on),
    /// else PM_ACC. PM_ACC_DSD (044B) is shown next to them.
    var sootLoad: Double? { sootGenerated ?? soot }

    /// The hottest exhaust / DPF temperature reported, °C.
    var hottestExhaust: Double? {
        (Array(exhaustTemps.values) + [dpfInletTemp, dpfOutletTemp].compactMap { $0 }).max()
    }
}
