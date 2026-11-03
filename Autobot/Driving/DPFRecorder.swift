// DPFRecorder.swift
// Autobot's DPF data recorder, for finding out why the DPF regenerates so often. While live data runs
// (DPF screen open or not) it takes a snapshot of the PCM's soot model and of what feeds it, writes it
// as one CSV row, and works out how fast PM_GEN — the soot the PCM's model says the engine has made
// since the last regeneration — grows: per 100 km since the last regeneration and over the last ~10 km,
// per hour, and how far it is to the ~5.6 g/L that starts the next regeneration. Everything can be
// exported from the DPF screen (CSV + JSON).
//
//   a sample every 30 s (every 10 s while the request flag 220380 is on, and for 20 min after the count
//   220432 goes up: a regeneration is starting or running):
//     every sample  RPM, PM_GEN / PM_ACC_DSD / PM_ACC (042D / 042B / 042C), request flag 0380, count
//                   0432, distance 0434, load, air flow, fuel rate, EGR, exhaust / DPF temperatures,
//                   DPF pressure                                                   (tier .fast)
//     every 30 s    + coolant, oil, MAP, boost, intake shutter, exhaust pressure, injection timing,
//                   torque, rail pressure, pedal, VGT / wastegate                  (tier .normal)
//                   + the next DIDs of a sweep through 7E0 0300–04FF and DA00–DAFF, raw only: the Mazda
//                   DIDs of the exhaust temperatures, the DPF differential pressure, the exhaust flow and
//                   the injected fuel aren't published, so they're looked for in the data afterwards
//     every 2 min   + odometer, intake / outside air, barometer, fuel level, run time, charge air, turbo,
//                   oil dilution, community candidates (044B, 03DB, 03FB, 03DF, 0301, 1305, DAAE)  (.slow)
//     once a drive  the supported-PID bitmaps 22F400…F4C0 (standard PIDs the PCM leaves out aren't
//                   asked), the PCM's software / calibration IDs, reference torque   (.once)
//   a few reads at a time between two live-data rounds (AppConfig.DPF.recordJobBudget), so Power Mode,
//   reverse and the turn signals keep working
//   -> Application Support/DPFRecorder/autobot-dpf-samples.csv: one row per sample — decoded values, the
//      PM_GEN rates, events (request flag, count, distance reset, PM_GEN drop, PM_ACC_DSD jump) and every
//      raw reply ("042D:01EF 042B:0045 …") in the last column
//   -> state.json: drives (supported PIDs, IDs, what wasn't answered), events, this regeneration cycle
//      (for the rates), the sweep's progress
//   -> export: the CSV file(s) + autobot-dpf-info.json (column dictionary, drives, events, the sweep, the
//      regeneration log, the PCM history finder)
//
// Nothing is recorded in test mode. Values, scaling and sources: README "DPF data recorder".

import Combine
import Foundation

private typealias Tuning = AppConfig.DPF

// MARK: - What is read

/// One value the recorder reads from the PCM (7E0, service 22) and the CSV columns it fills.
nonisolated struct DPFRecordField: Sendable {
    nonisolated enum Tier: Sendable {
        /// Every sample (every 10 s around a regeneration).
        case fast
        /// Every 30 s.
        case normal
        /// Every 2 min.
        case slow
        /// Once a drive.
        case once
    }

    /// "042D", or "F45E": the standard mode 01 PID 5E mirrored as a DID.
    let did: String
    let tier: Tier
    /// The CSV columns it fills; empty: kept raw only (the `raw` column).
    let columns: [String]
    /// What it is, unit and formula, for the export's column dictionary.
    let note: String
    /// A reply longer than one CAN frame (more than 4 data bytes): read to the end.
    let multiFrame: Bool
    /// One value per column; nil where the reply doesn't hold it.
    let decode: @Sendable ([UInt8]) -> [Double?]

    /// The standard PID behind an F4xx DID, for the support bitmaps; nil for Mazda DIDs.
    var standardPID: UInt8? {
        guard did.count == 4, did.hasPrefix("F4") else { return nil }
        return UInt8(did.dropFirst(2), radix: 16)
    }
}

/// What the recorder reads, and how (README "DPF data recorder").
nonisolated enum DPFRecordPlan {

    /// Read once a drive, before the rest: which standard PIDs the PCM supports (4-byte bitmaps, SAE
    /// J1979 PIDs 00, 20 … C0 mirrored as DIDs). A standard PID left out of an answered bitmap isn't
    /// asked on that drive.
    static let supportDIDs = ["F400", "F420", "F440", "F460", "F480", "F4A0", "F4C0"]

    /// Read once a drive, raw (ASCII in the export): the PCM's software / part number (UDS F188 / F187)
    /// and its calibration ID / verification number (mode 09 PIDs 04 / 06 mirrored as F804 / F806).
    /// Owners report that a newer PCM calibration makes PM_GEN grow faster, so which one is on the car
    /// matters.
    static let idDIDs = ["F188", "F187", "F804", "F806"]

    static let fields: [DPFRecordField] = [
        // The soot model and the regeneration: Mazda DIDs, community scaling (MazdaDPF.swift).
        field("042D", .fast, ["pm_gen"], """
              PM_GEN: soot generated since the last regeneration, modelled from engine speed, intake air and \
              injected fuel (Mazda). (A·256+B)·100/65536 g/L (community; another list uses /628)
              """) {
            [MazdaDPF.soot($0)]
        },
        field("042B", .fast, ["pm_acc_dsd"],
              "PM_ACC_DSD: the PCM's determined / target PM accumulation. (A·256+B)·100/65536 g/L (community)") {
            [MazdaDPF.soot($0)]
        },
        field("042C", .fast, ["pm_acc"],
              "PM_ACC: accumulated PM. (A·256+B)·100/65536 g/L (community)") {
            [MazdaDPF.soot($0)]
        },
        field("0380", .fast, ["regen_req"], """
              Regeneration request flag byte A (bit 0 = requested; drops while stopped although the \
              regeneration carries on). Raw byte value
              """) {
            [byte($0, 0)]
        },
        field("0432", .fast, ["regen_count"],
              "Regeneration count A·256+B (community: goes up as one starts; count − 1 = completed)") {
            [MazdaDPF.regenCount($0).map { Double($0) }]
        },
        field("0434", .fast, ["regen_km"],
              "Distance since the last regeneration (B·65536+C·256+D)·100/65536 km (another list: ·1/640)") {
            [MazdaDPF.regenDistance($0)]
        },
        // What the soot model works from, as standard PIDs (where this PCM supports them).
        field("F404", .fast, ["load_pct"], "PID 04 calculated load A·100/255 %") {
            [percent(byte($0, 0))]
        },
        field("F410", .fast, ["maf_gs"], "PID 10 mass air flow (A·256+B)/100 g/s") {
            [word($0, 0).map { $0 / 100 }]
        },
        field("F466", .fast, ["maf_a_gs", "maf_b_gs"],
              "PID 66 mass air flow sensors A / B: (B·256+C)/32, (D·256+E)/32 g/s", multiFrame: true) { d in
            [flagged(d, 0x01, word(d, 1).map { $0 / 32 }), flagged(d, 0x02, word(d, 3).map { $0 / 32 })]
        },
        field("F45E", .fast, ["fuel_rate_lh"], "PID 5E engine fuel rate (A·256+B)/20 L/h") {
            [word($0, 0).map { $0 / 20 }]
        },
        field("F49D", .fast, ["fuel_rate_gs"], "PID 9D engine fuel rate (A·256+B)·0.02 g/s") {
            [word($0, 0).map { $0 * 0.02 }]
        },
        field("F49E", .fast, ["exhaust_flow_kgh"], "PID 9E engine exhaust flow rate (A·256+B)·0.2 kg/h") {
            [word($0, 0).map { $0 * 0.2 }]
        },
        field("F469", .fast, ["egr_a_cmd_pct", "egr_a_act_pct", "egr_b_cmd_pct", "egr_b_act_pct"],
              "PID 69 EGR A (hot) commanded B / actual C, B (cooled) commanded E / actual F, ·100/255 %",
              multiFrame: true) { d in
            [flagged(d, 0x01, percent(byte(d, 1))), flagged(d, 0x02, percent(byte(d, 2))),
             flagged(d, 0x08, percent(byte(d, 4))), flagged(d, 0x10, percent(byte(d, 5)))]
        },
        field("F478", .fast, ["egt1_c", "egt2_c", "egt3_c", "egt4_c"],
              "PID 78 exhaust gas temperatures bank 1 sensors 1–4: raw/10 − 40 °C", multiFrame: true) { d in
            let temps = MazdaDPF.exhaustTemps(d)
            return [temps[1], temps[2], temps[3], temps[4]]
        },
        field("F47C", .fast, ["dpf_in_c", "dpf_out_c"],
              "PID 7C DPF inlet / outlet temperature: raw/10 − 40 °C", multiFrame: true) { d in
            let temps = MazdaDPF.dpfTemps(d)
            return [temps.inlet, temps.outlet]
        },
        field("F47A", .fast, ["dpf_dp_kpa", "dpf_in_kpa", "dpf_out_kpa"],
              "PID 7A DPF differential (signed) / inlet / outlet pressure ·0.01 kPa", multiFrame: true) { d in
            let pressure = MazdaDPF.pressure(d)
            return [pressure?.differential, pressure?.inlet, pressure?.outlet]
        },
        // Every 30 s.
        field("F405", .normal, ["coolant_c"], "PID 05 coolant A − 40 °C") {
            [celsius(byte($0, 0))]
        },
        field("F45C", .normal, ["oil_c"], "PID 5C engine oil temperature A − 40 °C (the trigger is ~5.6 g/L above 80 °C)") {
            [celsius(byte($0, 0))]
        },
        field("F40B", .normal, ["map_kpa"], "PID 0B intake manifold absolute pressure A kPa") {
            [byte($0, 0)]
        },
        field("F470", .normal, ["boost_target_kpa", "boost_kpa"],
              "PID 70 boost commanded (B·256+C)/32, actual (D·256+E)/32 kPa abs", multiFrame: true) { d in
            let boost = MazdaDPF.boost(d)
            return [boost.target, boost.actual]
        },
        field("F411", .normal, ["isv_pct"], "PID 11 throttle (intake shutter valve) position A·100/255 %") {
            [percent(byte($0, 0))]
        },
        field("F46A", .normal, ["isv_a_cmd_pct", "isv_a_pos_pct"],
              "PID 6A diesel intake air flow control A: commanded B / relative position C ·100/255 % (ISV_DSD vs ISV_POS)",
              multiFrame: true) { d in
            [flagged(d, 0x01, percent(byte(d, 1))), flagged(d, 0x02, percent(byte(d, 2)))]
        },
        field("F42C", .normal, ["egr_cmd_pct"], "PID 2C commanded EGR A·100/255 %") {
            [percent(byte($0, 0))]
        },
        field("F42D", .normal, ["egr_error_pct"], "PID 2D EGR error A·100/128 − 100 %") {
            [byte($0, 0).map { $0 * 100 / 128 - 100 }]
        },
        field("F473", .normal, ["exhaust_kpa"], "PID 73 exhaust pressure bank 1 (B·256+C)/100 kPa",
              multiFrame: true) {
            [MazdaDPF.exhaustPressure($0)]
        },
        field("F45D", .normal, ["injection_timing_deg"], "PID 5D fuel injection timing (A·256+B)/128 − 210 °") {
            [word($0, 0).map { $0 / 128 - 210 }]
        },
        field("F461", .normal, ["torque_demand_pct"], "PID 61 driver's demand torque A − 125 %") {
            [byte($0, 0).map { $0 - 125 }]
        },
        field("F462", .normal, ["torque_pct"], "PID 62 actual engine torque A − 125 % (× reference torque)") {
            [byte($0, 0).map { $0 - 125 }]
        },
        field("F423", .normal, ["rail_kpa"], "PID 23 fuel rail gauge pressure (A·256+B)·10 kPa") {
            [word($0, 0).map { $0 * 10 }]
        },
        field("F46D", .normal, ["rail_cmd_kpa", "rail_act_kpa"],
              "PID 6D fuel pressure control: commanded (B·256+C)·10, actual (D·256+E)·10 kPa", multiFrame: true) { d in
            [flagged(d, 0x01, word(d, 1).map { $0 * 10 }), flagged(d, 0x02, word(d, 3).map { $0 * 10 })]
        },
        field("F449", .normal, ["pedal_pct"], "PID 49 accelerator pedal position D A·100/255 %") {
            [percent(byte($0, 0))]
        },
        field("F471", .normal, ["vgt_cmd_pct", "vgt_act_pct"],
              "PID 71 VGT A commanded B / position C ·100/255 %", multiFrame: true) { d in
            [flagged(d, 0x01, percent(byte(d, 1))), flagged(d, 0x02, percent(byte(d, 2)))]
        },
        field("F472", .normal, ["wastegate_cmd_pct", "wastegate_act_pct"],
              "PID 72 wastegate A commanded B / position C ·100/255 %", multiFrame: true) { d in
            [flagged(d, 0x01, percent(byte(d, 1))), flagged(d, 0x02, percent(byte(d, 2)))]
        },
        // Every 2 min.
        field("DD01", .slow, ["odometer_km"], "Odometer A·65536+B·256+C km") {
            [MazdaDPF.odometer($0)]
        },
        field("F40F", .slow, ["intake_air_c"], "PID 0F intake air temperature A − 40 °C") {
            [celsius(byte($0, 0))]
        },
        field("F446", .slow, ["ambient_c"], "PID 46 ambient air temperature A − 40 °C") {
            [celsius(byte($0, 0))]
        },
        field("F433", .slow, ["baro_kpa"], "PID 33 barometric pressure A kPa") {
            [byte($0, 0)]
        },
        field("F42F", .slow, ["fuel_level_pct"], "PID 2F fuel tank level A·100/255 %") {
            [percent(byte($0, 0))]
        },
        field("F41F", .slow, ["run_s"], "PID 1F run time since engine start A·256+B s") {
            [word($0, 0)]
        },
        field("F477", .slow, ["charge_air1_c", "charge_air2_c"], "PID 77 charge air cooler temperatures B, C − 40 °C",
              multiFrame: true) { d in
            let temps = MazdaDPF.chargeAir(d)
            return [temps[1], temps[2]]
        },
        field("F474", .slow, ["turbo_rpm"], "PID 74 turbocharger A speed (B·256+C)·10 rpm", multiFrame: true) { d in
            [flagged(d, 0x01, word(d, 1).map { $0 * 10 })]
        },
        raw("F475", .slow, "PID 75 turbocharger A temperatures (raw)", multiFrame: true),
        raw("F476", .slow, "PID 76 turbocharger B temperatures (raw)", multiFrame: true),
        raw("F46B", .slow, "PID 6B EGR temperatures (raw)", multiFrame: true),
        raw("F46F", .slow, "PID 6F turbocharger compressor inlet pressure (raw)"),
        raw("F48B", .slow, "PID 8B diesel aftertreatment status (raw; not answered on the 2015 KE so far)",
            multiFrame: true),
        field("03E1", .slow, ["oil_dilution_raw"], "Fuel in the oil? A·256+B, unit unproven (low confidence)") {
            [word($0, 0)]
        },
        field("0435", .slow, ["oil_dilution_events"], "Oil-dilution events? A (low confidence)") {
            [byte($0, 0)]
        },
        // Community candidates, unconfirmed on this PCM: raw only, to compare with the rest afterwards.
        raw("044B", .slow, "Unlabelled PM value, (A·256+B)/628 g/L? (one community list)"),
        raw("03DB", .slow, "Exhaust differential pressure sensor voltage (A·256+B)/200 V? (MZR-CD list)"),
        raw("03FB", .slow, "EGR or VGT position? (lists disagree)"),
        raw("03DF", .slow, "VGT (A·256+B)·100/65535 %? (one list)"),
        raw("0301", .slow, "MAP sensor voltage (A·256+B)/1000 V? (one list)"),
        raw("1305", .slow, "Target boost ((A·256+B)/64)/100 bar? (one list)"),
        raw("DAAE", .slow, "Fuel injection amount learning: count / distance? (one list)", multiFrame: true),
        // Once a drive.
        field("F463", .once, ["torque_ref_nm"], "PID 63 engine reference torque A·256+B Nm") {
            [word($0, 0)]
        },
    ]

    // MARK: Building blocks

    private static func field(_ did: String, _ tier: DPFRecordField.Tier, _ columns: [String], _ note: String,
                              multiFrame: Bool = false,
                              _ decode: @escaping @Sendable ([UInt8]) -> [Double?]) -> DPFRecordField {
        DPFRecordField(did: did, tier: tier, columns: columns, note: note, multiFrame: multiFrame, decode: decode)
    }

    /// A value kept raw only (the `raw` column).
    private static func raw(_ did: String, _ tier: DPFRecordField.Tier, _ note: String,
                            multiFrame: Bool = false) -> DPFRecordField {
        DPFRecordField(did: did, tier: tier, columns: [], note: note, multiFrame: multiFrame, decode: { _ in [] })
    }

    private static func byte(_ data: [UInt8], _ index: Int) -> Double? {
        index < data.count ? Double(data[index]) : nil
    }

    private static func word(_ data: [UInt8], _ index: Int) -> Double? {
        index + 1 < data.count ? Double(Int(data[index]) << 8 | Int(data[index + 1])) : nil
    }

    private static func percent(_ value: Double?) -> Double? {
        value.map { $0 * 100 / 255 }
    }

    private static func celsius(_ value: Double?) -> Double? {
        value.map { $0 - 40 }
    }

    /// `value` when bit `mask` of byte A (the fields the reply holds) is set.
    private static func flagged(_ data: [UInt8], _ mask: UInt8, _ value: Double?) -> Double? {
        guard let bits = data.first, bits & mask != 0 else { return nil }
        return value
    }
}

// MARK: - The recorder

final class DPFRecorder: ObservableObject {

    /// How fast PM_GEN (and PM_ACC_DSD) grow, worked out after every sample.
    struct Rate: Codable, Equatable {
        /// PM_GEN per 100 km since the last regeneration (PM_GEN ÷ distance since it), g/L.
        var sinceRegen: Double?
        /// PM_GEN per 100 km over the last ~rateWindowKm of this regeneration cycle, g/L…
        var recent: Double?
        /// …over this many km.
        var recentKm: Double?
        /// PM_GEN per hour over the last ~rateWindowMinutes of this drive, g/L.
        var perHour: Double?
        /// PM_ACC_DSD per 100 km over the same stretch as `recent`, g/L.
        var dsdRecent: Double?
        /// km until PM_GEN reaches Tuning.pmGenTrigger at the recent pace (else the one since the last
        /// regeneration).
        var kmToTrigger: Double?
        /// Fuel used since the last regeneration (litres, from the fuel rate PID), when all of it was
        /// recorded, and PM_GEN per litre.
        var fuelSinceRegen: Double?
        var perLitre: Double?
        /// What it was worked out from.
        var pmGen: Double?
        var regenKm: Double?
        var time: Date?
    }

    /// One drive (live data from start to stop) and what the PCM said about itself on it.
    struct Drive: Codable, Equatable {
        /// "20261104-0815"
        var id: String
        var start: Date
        var end: Date?
        var samples = 0
        /// Supported-PID bitmaps: "F400" -> "98 3B A0 13", or why there's none.
        var support: [String: String] = [:]
        /// Software / calibration IDs: "F188" -> "53 48 …  (SH…)".
        var ids: [String: String] = [:]
        /// Values not read on this drive and why: "F45E" -> "7F 22 31 …" / "no reply" / "not supported".
        var notAnswered: [String: String] = [:]
    }

    /// Something that happened, for the export (the important ones also go to the dashboard log).
    struct Event: Codable, Equatable {
        var time: Date
        var drive: String
        var sample: Int
        var text: String
    }

    @Published private(set) var status = "Not recording"
    @Published private(set) var isRecording = false
    @Published private(set) var rate = Rate()
    /// Samples recorded since the data was last cleared / on this drive.
    @Published private(set) var sampleCount = 0
    @Published private(set) var driveSamples = 0
    @Published private(set) var lastSample: Date?
    /// Size of the recorded CSV file(s), bytes.
    @Published private(set) var fileBytes = 0
    /// What the export shares: the CSV file(s) and the info JSON.
    @Published private(set) var exportFiles: [URL] = []
    /// "312 answer · 410 not there · 46 not tried yet"
    @Published private(set) var sweepSummary = ""

    var onLog: ((String) -> Void)?

    /// Everything the recorder keeps between launches (state.json).
    private struct State: Codable {
        var sampleNumber = 0
        var drives: [Drive] = []
        var events: [Event] = []
        /// This regeneration cycle (since PM_GEN or the distance last went back down), for the rates.
        var cycle: [CyclePoint] = []
        /// Fuel used in this cycle (litres), and whether all of the cycle was recorded with it.
        var cycleFuel: Double?
        var cycleFuelComplete = false
        /// The previous sample's values, for the events and the fuel used.
        var last: Last?
        /// The sweep: DIDs that aren't there (refused, or no reply twice), no-reply counts, the next one,
        /// and the latest reply of the ones that answer.
        var sweepAbsent: Set<String> = []
        var sweepSilent: [String: Int] = [:]
        var sweepCursor = 0
        var sweepAnswered: [String: String] = [:]
        /// Every sample fast until then: the count went up (a regeneration started).
        var fastUntil: Date?
    }

    private struct CyclePoint: Codable {
        var time: Date
        var drive: String
        var regenKm: Double
        var pmGen: Double?
        var pmDsd: Double?
    }

    private struct Last: Codable {
        var time: Date
        var drive: String
        var regenReq: Int?
        var count: Int?
        var regenKm: Double?
        var pmGen: Double?
        var pmDsd: Double?
        var fuelRate: Double?
    }

    /// One read in a go between two live-data rounds.
    private enum Read {
        case rpm
        /// A PCM DID, read to the end when `multiFrame`; `sweep`: one of the sweep's (shorter wait).
        case did(String, multiFrame: Bool, sweep: Bool)
    }

    private struct Reply {
        let did: String
        let sweep: Bool
        let reply: OBDAdapter.UDSReply
    }

    private struct Chunk {
        var rpm: Double?
        var replies: [Reply] = []
    }

    private let obd: OBDAdapter
    private let regenLog: DPFRegenLog
    private let history: DPFHistoryFinder
    private let persist = Tuning.recordEnabled && !AppConfig.TestMode.enabled
    private let directory: URL?
    private var state = State()
    private var task: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    /// The drive being recorded; nil while live data isn't running.
    private var drive: Drive?
    /// This drive: values not asked again, no-reply counts, once-a-drive values done, the bitmaps
    /// (base PID 00, 20 … -> 4 bytes), when the 30 s and 2 min values were last read.
    private var skipped: Set<String> = []
    private var misses: [String: Int] = [:]
    private var onceDone: Set<String> = []
    private var bitmaps: [UInt8: [UInt8]] = [:]
    private var driveInfoRead = false
    private var lastNormal: Date?
    private var lastSlow: Date?
    /// The DPF screen is showing: the export is kept up to date after every sample.
    private var screenOpen = false

    private static let csvName = "autobot-dpf-samples.csv"
    private static let infoName = "autobot-dpf-info.json"

    /// The CSV columns: sample, the PM_GEN rates, the decoded values, then the events and every raw reply.
    private static let metaColumns = ["time", "unix", "drive", "sample", "kind", "speed_kmh", "rpm"]
    private static let rateColumns = ["pm_gen_per_100km_since_regen", "pm_gen_per_100km_recent", "recent_window_km",
                                      "pm_gen_per_hour_recent", "pm_acc_dsd_per_100km_recent", "km_to_trigger",
                                      "fuel_l_since_regen", "pm_gen_per_litre"]
    private static let fieldColumns: [String] = DPFRecordPlan.fields.flatMap(\.columns)
    private static let header: [String] = metaColumns + rateColumns + fieldColumns + ["events", "raw"]

    /// The sweep's DIDs in order: AppConfig.DPF.recordSweepRanges without the ones read as fields.
    private static let sweepDIDs: [String] = {
        let fieldDIDs = Set(DPFRecordPlan.fields.map(\.did))
        return Tuning.recordSweepRanges.flatMap { range in range.map { DPFRecorder.didText($0) } }
            .filter { !fieldDIDs.contains($0) }
    }()

    private static let isoTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    init(obd: OBDAdapter, regenLog: DPFRegenLog, history: DPFHistoryFinder) {
        self.obd = obd
        self.regenLog = regenLog
        self.history = history
        let recording = Tuning.recordEnabled && !AppConfig.TestMode.enabled
        directory = recording ? DPFRecorder.makeDirectory() : nil
        if persist {
            state = Self.loadState(from: stateURL) ?? State()
            prepareCSV()
        }
        sampleCount = state.sampleNumber
        status = idleStatus
        updateFiles()
        updateSweepSummary()
        obd.$isReady
            .removeDuplicates()
            .sink { [weak self] ready in self?.liveDataChanged(ready) }
            .store(in: &subscriptions)
    }

    // MARK: Actions

    /// The DPF screen opened: from now on the export is kept up to date after every sample.
    func screenOpened() {
        screenOpen = true
        refreshExport()
    }

    func screenClosed() {
        screenOpen = false
    }

    /// Deletes the recorded samples, drives and events. What the sweep found about the PCM is kept.
    func clear() {
        for url in csvFiles() { try? FileManager.default.removeItem(at: url) }
        var fresh = State()
        fresh.sweepAbsent = state.sweepAbsent
        fresh.sweepSilent = state.sweepSilent
        fresh.sweepCursor = state.sweepCursor
        fresh.sweepAnswered = state.sweepAnswered
        if var current = drive {
            current.samples = 0
            drive = current
            fresh.drives = [current]
        }
        state = fresh
        prepareCSV()
        sampleCount = 0
        driveSamples = 0
        lastSample = nil
        rate = Rate()
        saveState()
        updateFiles()
        refreshExport()
        onLog?("DPF recorder: recorded data cleared")
    }

    // MARK: Drives

    private func liveDataChanged(_ ready: Bool) {
        task?.cancel()
        task = nil
        if ready {
            guard persist else { return }
            startDrive()
            task = Task { [weak self] in await self?.run() }
        } else {
            endDrive()
        }
    }

    private func startDrive() {
        let now = Date()
        let id = Self.stamp.string(from: now)
        let newDrive = Drive(id: id, start: now)
        drive = newDrive
        state.drives.append(newDrive)
        if state.drives.count > Tuning.recordMaxDrives {
            state.drives.removeFirst(state.drives.count - Tuning.recordMaxDrives)
        }
        skipped = []
        misses = [:]
        onceDone = []
        bitmaps = [:]
        driveInfoRead = false
        lastNormal = nil
        lastSlow = nil
        driveSamples = 0
        isRecording = true
        status = "Starting…"
        saveState()
        onLog?(String(format: "DPF recorder: recording every %.0f s (every %.0f s around a regeneration)",
                      Tuning.recordInterval, Tuning.recordIntervalDuringRegen))
    }

    private func endDrive() {
        guard drive != nil else { return }
        updateDrive { $0.end = Date() }
        drive = nil
        isRecording = false
        status = idleStatus
        saveState()
        if screenOpen { refreshExport() }
    }

    private func updateDrive(_ change: (inout Drive) -> Void) {
        guard var current = drive else { return }
        change(&current)
        drive = current
        if let index = state.drives.lastIndex(where: { $0.id == current.id }) {
            state.drives[index] = current
        }
    }

    private var idleStatus: String {
        if !Tuning.recordEnabled { return "Off (AppConfig.DPF.recordEnabled)" }
        if AppConfig.TestMode.enabled { return "Test mode: nothing is recorded" }
        return "Waiting for live data (adapter connected, engine running)"
    }

    // MARK: Sampling

    private func run() async {
        try? await Task.sleep(for: .seconds(Tuning.recordFirstDelay))
        while !Task.isCancelled {
            let started = Date()
            let fast = isFast(at: started)
            await sample(fast: fast, at: started)
            guard !Task.isCancelled else { return }
            let interval = fast ? Tuning.recordIntervalDuringRegen : Tuning.recordInterval
            let wait = started.addingTimeInterval(interval).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
    }

    /// Every 10 s while the request flag is on, or for a while after the count went up.
    private func isFast(at date: Date) -> Bool {
        if let request = state.last?.regenReq, request & Int(MazdaDPF.regenStatusMask) != 0 { return true }
        if let until = state.fastUntil, date < until { return true }
        return false
    }

    private func sample(fast: Bool, at started: Date) async {
        guard drive != nil else { return }
        if !driveInfoRead {
            guard await readDriveInfo() else { return }          // live data stopped meanwhile
        }
        guard let driveID = drive?.id else { return }
        let speed = obd.sample?.speed
        let normal = lastNormal.map { started.timeIntervalSince($0) >= Tuning.recordInterval - 1 } ?? true
        let slow = lastSlow.map { started.timeIntervalSince($0) >= Tuning.recordSlowInterval - 1 } ?? true
        var reads: [Read] = [.rpm]
        for field in DPFRecordPlan.fields where wanted(field, normal: normal, slow: slow) {
            reads.append(.did(field.did, multiFrame: field.multiFrame, sweep: false))
        }
        let sweep = normal ? nextSweep(Tuning.recordSweepPerSample) : []
        reads += sweep.map { Read.did($0, multiFrame: false, sweep: true) }

        guard let (chunk, cut) = await readAll(reads) else { return }
        if normal { lastNormal = started }
        if slow { lastSlow = started }
        for field in DPFRecordPlan.fields where field.tier == .once { onceDone.insert(field.did) }

        // What came back.
        var data: [String: [UInt8]] = [:]
        var rawParts: [String] = []
        var newlySkipped: [String] = []
        for item in chunk.replies {
            switch item.reply {
            case .data(let bytes):
                data[item.did] = bytes
                rawParts.append(item.did + ":" + Self.hex(bytes, separator: ""))
                if item.sweep {
                    state.sweepAnswered[item.did] = Self.hex(bytes)
                    state.sweepSilent[item.did] = nil
                } else {
                    misses[item.did] = 0
                }
            case .refused(let code):
                if item.sweep {
                    markAbsent(item.did)
                } else {
                    skip(item.did, why: String(format: "7F 22 %02X ", code) + ELM327.negativeResponseName(code))
                    newlySkipped.append(item.did)
                }
            case .silent:
                if item.sweep {
                    let count = (state.sweepSilent[item.did] ?? 0) + 1
                    state.sweepSilent[item.did] = count
                    if count >= 2 { markAbsent(item.did) }
                } else {
                    let count = (misses[item.did] ?? 0) + 1
                    misses[item.did] = count
                    if count >= Tuning.missesBeforeSkipping {
                        skip(item.did, why: "no reply")
                        newlySkipped.append(item.did)
                    }
                }
            }
        }
        if !newlySkipped.isEmpty {
            onLog?("DPF recorder: not answered, not asked again this drive: " + newlySkipped.joined(separator: ", "))
        }
        updateSweepSummary()
        guard !data.isEmpty || chunk.rpm != nil else {
            saveState()
            return
        }

        // Decoded values.
        var values: [String: Double] = [:]
        for field in DPFRecordPlan.fields {
            guard let bytes = data[field.did] else { continue }
            for (column, value) in zip(field.columns, field.decode(bytes)) {
                if let value, value.isFinite { values[column] = value }
            }
        }
        let request = data["0380"]?.first.map { Int($0) }
        let count = values["regen_count"].map { Int($0) }
        let regenKm = values["regen_km"]
        let pmGen = values["pm_gen"]
        let pmDsd = values["pm_acc_dsd"]
        let fuelRate = values["fuel_rate_lh"]

        state.sampleNumber += 1
        let number = state.sampleNumber
        var events = changes(request: request, count: count, regenKm: regenKm, pmGen: pmGen, pmDsd: pmDsd,
                             at: started)
        if driveSamples == 0 { events.insert("drive start", at: 0) }
        if cut { events.append("cut short: live data stopped") }
        updateCycle(at: started, drive: driveID, regenKm: regenKm, pmGen: pmGen, pmDsd: pmDsd, fuelRate: fuelRate)
        let newRate = makeRate(at: started, drive: driveID, pmGen: pmGen, pmDsd: pmDsd, regenKm: regenKm)

        // The row.
        var cells: [String] = [
            Self.isoTime.string(from: started),
            String(format: "%.0f", started.timeIntervalSince1970),
            driveID,
            String(number),
            fast ? "regen" : "normal",
            Self.format(speed),
            Self.format(chunk.rpm),
        ]
        cells += [newRate.sinceRegen, newRate.recent, newRate.recentKm, newRate.perHour, newRate.dsdRecent,
                  newRate.kmToTrigger, newRate.fuelSinceRegen, newRate.perLitre].map { Self.format($0) }
        cells += Self.fieldColumns.map { Self.format(values[$0]) }
        cells.append(events.joined(separator: "; ").replacingOccurrences(of: ",", with: ";"))
        cells.append(rawParts.joined(separator: " "))
        append(cells.joined(separator: ","))

        // Keep track.
        let previous = state.last
        state.last = Last(time: started, drive: driveID,
                          regenReq: request ?? previous?.regenReq, count: count ?? previous?.count,
                          regenKm: regenKm ?? previous?.regenKm, pmGen: pmGen ?? previous?.pmGen,
                          pmDsd: pmDsd ?? previous?.pmDsd, fuelRate: fuelRate)
        for text in events {
            state.events.append(Event(time: started, drive: driveID, sample: number, text: text))
        }
        if state.events.count > Tuning.recordMaxEvents {
            state.events.removeFirst(state.events.count - Tuning.recordMaxEvents)
        }
        let worthLogging = events.filter { !$0.hasPrefix("drive start") && !$0.hasPrefix("cut short") }
        if !worthLogging.isEmpty {
            var line = "DPF recorder: " + worthLogging.joined(separator: " · ")
            if let pmGen { line += String(format: " · PM_GEN %.2f", pmGen) }
            if let pmDsd { line += String(format: " · PM_ACC_DSD %.2f", pmDsd) }
            if let regenKm { line += String(format: " · %.1f km", regenKm) }
            onLog?(line)
        }
        updateDrive { $0.samples += 1 }
        driveSamples += 1
        sampleCount = number
        lastSample = started
        rate = newRate
        status = String(format: fast ? "Recording every %.0f s (regeneration)" : "Recording every %.0f s",
                        fast ? Tuning.recordIntervalDuringRegen : Tuning.recordInterval)
        saveState()
        if screenOpen { refreshExport() }
    }

    /// Reads everything in short gos between two live-data rounds, each at most AppConfig.DPF.recordJobBudget
    /// (a single-frame read counts 1, one read to the end of several frames 3). nil if live data stopped
    /// before anything was read; `cut` if it stopped part-way.
    private func readAll(_ reads: [Read]) async -> (Chunk, cut: Bool)? {
        var result = Chunk()
        var index = 0
        while index < reads.count {
            let first = index
            var part: [Read] = []
            var cost = 0
            while index < reads.count {
                let next = Self.cost(of: reads[index])
                if !part.isEmpty, cost + next > Tuning.recordJobBudget { break }
                part.append(reads[index])
                cost += next
                index += 1
            }
            let toRead = part
            guard !Task.isCancelled,
                  let chunk = await obd.runBetweenRounds({ adapter in await Self.read(toRead, with: adapter) }) else {
                return first == 0 ? nil : (result, true)
            }
            if let rpm = chunk.rpm { result.rpm = rpm }
            result.replies += chunk.replies
        }
        return (result, false)
    }

    /// How long a read keeps live data waiting, roughly: one CAN frame 1, a reply of several frames 3.
    private static func cost(of read: Read) -> Int {
        switch read {
        case .rpm: return 1
        case .did(_, let multiFrame, _): return multiFrame ? 3 : 1
        }
    }

    /// One go, with the adapter to itself (between two live-data rounds).
    private static func read(_ reads: [Read], with adapter: OBDAdapter) async -> Chunk {
        var chunk = Chunk()
        for read in reads {
            switch read {
            case .rpm:
                chunk.rpm = await adapter.readRPM()
            case .did(let did, let multiFrame, let sweep):
                let reply = await adapter.probeDID(did, from: MazdaDPF.header, complete: multiFrame,
                                                   timeout: sweep ? Tuning.recordSweepTimeout : AppConfig.OBD.replyTimeout)
                chunk.replies.append(Reply(did: did, sweep: sweep, reply: reply))
            }
        }
        return chunk
    }

    /// Once a drive, before the first sample: the supported-PID bitmaps and the PCM's IDs. False if live
    /// data stopped meanwhile.
    private func readDriveInfo() async -> Bool {
        var reads = DPFRecordPlan.supportDIDs.map { Read.did($0, multiFrame: false, sweep: false) }
        reads += DPFRecordPlan.idDIDs.map { Read.did($0, multiFrame: true, sweep: false) }
        guard let (chunk, cut) = await readAll(reads), !cut else { return false }
        var support: [String: String] = [:]
        var ids: [String: String] = [:]
        for item in chunk.replies {
            let text: String
            switch item.reply {
            case .data(let bytes):
                text = Self.hex(bytes)
                if DPFRecordPlan.supportDIDs.contains(item.did), bytes.count >= 4,
                   let base = UInt8(item.did.dropFirst(2), radix: 16) {
                    bitmaps[base] = Array(bytes.prefix(4))
                }
                if DPFRecordPlan.idDIDs.contains(item.did) {
                    ids[item.did] = text + "  (" + Self.ascii(bytes) + ")"
                }
            case .refused(let code):
                text = String(format: "7F 22 %02X ", code) + ELM327.negativeResponseName(code)
            case .silent:
                text = "no reply"
            }
            if DPFRecordPlan.supportDIDs.contains(item.did) { support[item.did] = text }
            if DPFRecordPlan.idDIDs.contains(item.did), ids[item.did] == nil { ids[item.did] = text }
        }
        var unsupported: [String: String] = [:]
        for field in DPFRecordPlan.fields {
            if let pid = field.standardPID, supports(pid) == false { unsupported[field.did] = "not supported (bitmap)" }
        }
        updateDrive { current in
            current.support = support
            current.ids = ids
            current.notAnswered.merge(unsupported) { old, _ in old }
        }
        driveInfoRead = true
        let standard = DPFRecordPlan.fields.compactMap { $0.standardPID }
        let supported = standard.filter { supports($0) == true }
        if !bitmaps.isEmpty {
            onLog?("DPF recorder: the PCM supports \(supported.count) of the \(standard.count) standard PIDs it records")
        }
        saveState()
        return true
    }

    private func wanted(_ field: DPFRecordField, normal: Bool, slow: Bool) -> Bool {
        guard !skipped.contains(field.did) else { return false }
        if let pid = field.standardPID, supports(pid) == false { return false }
        switch field.tier {
        case .fast: return true
        case .normal: return normal
        case .slow: return slow
        case .once: return !onceDone.contains(field.did)
        }
    }

    /// Whether the PCM's bitmap lists standard PID `pid`; nil if that range's bitmap didn't answer.
    private func supports(_ pid: UInt8) -> Bool? {
        guard pid > 0 else { return nil }
        let base = UInt8((Int(pid) - 1) / 32 * 32)
        guard let bitmap = bitmaps[base], bitmap.count >= 4 else { return nil }
        let index = Int(pid) - Int(base) - 1
        return bitmap[index / 8] & (UInt8(0x80) >> UInt8(index % 8)) != 0
    }

    private func skip(_ did: String, why: String) {
        skipped.insert(did)
        updateDrive { $0.notAnswered[did] = why }
    }

    // MARK: The sweep

    /// The next `count` DIDs of the sweep that may exist; the cursor moves on.
    private func nextSweep(_ count: Int) -> [String] {
        let all = Self.sweepDIDs
        guard !all.isEmpty, count > 0 else { return [] }
        var picked: [String] = []
        var cursor = state.sweepCursor % all.count
        var steps = 0
        while picked.count < count, steps < all.count {
            let did = all[cursor]
            if !state.sweepAbsent.contains(did) { picked.append(did) }
            cursor = (cursor + 1) % all.count
            steps += 1
        }
        state.sweepCursor = cursor
        return picked
    }

    private func markAbsent(_ did: String) {
        state.sweepAbsent.insert(did)
        state.sweepAnswered[did] = nil
        state.sweepSilent[did] = nil
    }

    private func updateSweepSummary() {
        let total = Self.sweepDIDs.count
        let answered = state.sweepAnswered.count
        let absent = state.sweepAbsent.count
        let untried = max(0, total - answered - absent)
        sweepSummary = "\(answered) answer · \(absent) not there" + (untried > 0 ? " · \(untried) not tried yet" : "")
    }

    // MARK: Events and rates

    /// What changed since the previous sample: the request flag, the count, the distance, PM_GEN falling,
    /// PM_ACC_DSD jumping.
    private func changes(request: Int?, count: Int?, regenKm: Double?, pmGen: Double?, pmDsd: Double?,
                         at date: Date) -> [String] {
        guard let last = state.last else { return [] }
        var events: [String] = []
        if let request, let old = last.regenReq, request != old {
            events.append("0380 request " + Self.hex([UInt8(truncatingIfNeeded: old)]) + "->"
                          + Self.hex([UInt8(truncatingIfNeeded: request)]))
        }
        if let count, let old = last.count, count != old {
            events.append("count \(old)->\(count)")
            if count > old { state.fastUntil = date.addingTimeInterval(Tuning.recordFastAfterCountUp) }
        }
        if let regenKm, let old = last.regenKm, regenKm < old - 1 {
            events.append(String(format: "distance reset %.1f->%.1f km", old, regenKm))
        }
        if let pmGen, let old = last.pmGen, pmGen < old - Tuning.recordGenDrop {
            events.append(String(format: "PM_GEN drop %.2f->%.2f", old, pmGen))
        }
        if let pmDsd, let old = last.pmDsd, abs(pmDsd - old) >= Tuning.recordDsdJump {
            events.append(String(format: "PM_ACC_DSD jump %.2f->%.2f", old, pmDsd))
        }
        return events
    }

    /// Adds this sample to the regeneration cycle (a new cycle when the distance or PM_GEN went back down)
    /// and adds up the fuel used.
    private func updateCycle(at date: Date, drive: String, regenKm: Double?, pmGen: Double?, pmDsd: Double?,
                             fuelRate: Double?) {
        let previous = state.cycle.last
        let sameDrive = state.last?.drive == drive
        var reset = false
        if let regenKm, let old = previous?.regenKm, regenKm < old - 1 { reset = true }
        if let pmGen, let old = previous?.pmGen, pmGen < old - Tuning.recordGenDrop { reset = true }
        if reset {
            state.cycle = []
            state.cycleFuel = 0
            state.cycleFuelComplete = sameDrive      // seen happening, so all of the new cycle is recorded
        } else if !sameDrive, let regenKm, let old = state.last?.regenKm, regenKm > old + 0.5 {
            state.cycleFuelComplete = false          // driven since the last drive without recording
        }
        if let fuelRate, sameDrive, let last = state.last, let oldRate = last.fuelRate {
            let seconds = date.timeIntervalSince(last.time)
            if seconds > 0, seconds <= Tuning.recordFuelGap {
                state.cycleFuel = (state.cycleFuel ?? 0) + (fuelRate + oldRate) / 2 * seconds / 3600
            } else {
                state.cycleFuelComplete = false
            }
        } else if sameDrive, state.last?.fuelRate != nil, fuelRate == nil {
            state.cycleFuelComplete = false          // a gap in the fuel rate
        }
        if let regenKm {
            state.cycle.append(CyclePoint(time: date, drive: drive, regenKm: regenKm, pmGen: pmGen, pmDsd: pmDsd))
            if state.cycle.count > Tuning.recordCycleMaxPoints {
                state.cycle.removeFirst(state.cycle.count - Tuning.recordCycleMaxPoints)
            }
        }
    }

    private func makeRate(at date: Date, drive: String, pmGen: Double?, pmDsd: Double?, regenKm: Double?) -> Rate {
        var result = Rate()
        result.pmGen = pmGen
        result.regenKm = regenKm
        result.time = date
        if state.cycleFuelComplete, let fuel = state.cycleFuel {
            result.fuelSinceRegen = fuel
            if let pmGen, fuel >= Tuning.rateMinFuel { result.perLitre = pmGen / fuel }
        }
        guard let pmGen, let regenKm else { return result }
        if regenKm >= Tuning.rateMinSinceRegenKm { result.sinceRegen = pmGen / regenKm * 100 }
        // The last ~rateWindowKm of this cycle (all of it while it's shorter).
        let cycle = state.cycle
        if let first = cycle.first {
            let start = cycle.last(where: { $0.regenKm <= regenKm - Tuning.rateWindowKm }) ?? first
            let km = regenKm - start.regenKm
            if km >= Tuning.rateMinKm {
                result.recentKm = km
                if let old = start.pmGen { result.recent = (pmGen - old) / km * 100 }
                if let pmDsd, let old = start.pmDsd { result.dsdRecent = (pmDsd - old) / km * 100 }
            }
        }
        // Per hour over the last ~rateWindowMinutes of this drive.
        let thisDrive = cycle.filter { $0.drive == drive }
        if let first = thisDrive.first {
            let start = thisDrive.last(where: { date.timeIntervalSince($0.time) >= Tuning.rateWindowMinutes * 60 }) ?? first
            let seconds = date.timeIntervalSince(start.time)
            if seconds >= Tuning.rateMinMinutes * 60, let old = start.pmGen {
                result.perHour = (pmGen - old) / seconds * 3600
            }
        }
        if pmGen >= Tuning.pmGenTrigger {
            result.kmToTrigger = 0
        } else if let pace = result.recent ?? result.sinceRegen, pace > 0.05 {
            result.kmToTrigger = (Tuning.pmGenTrigger - pmGen) / pace * 100
        }
        return result
    }

    // MARK: Files

    private static func makeDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = base.appendingPathComponent("DPFRecorder", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    private var csvURL: URL? { directory?.appendingPathComponent(Self.csvName) }
    private var stateURL: URL? { directory?.appendingPathComponent("state.json") }

    /// Makes sure the CSV file is there with today's columns; one with other columns (an older version)
    /// is kept under another name.
    private func prepareCSV() {
        guard let url = csvURL else { return }
        let header = Self.header.joined(separator: ",")
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            if Self.firstLine(of: url) == header { return }
            archive(url)
        }
        try? (header + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ line: String) {
        guard let url = csvURL, let data = (line + "\n").data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { prepareCSV() }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            onLog?("DPF recorder: couldn't write the sample (\(error.localizedDescription))")
        }
        if Self.size(of: url) > Tuning.recordMaxFileBytes {
            archive(url)
            prepareCSV()
            pruneArchives()
        }
        updateFiles()
    }

    /// Moves a CSV aside under a dated name (it stays in the export).
    private func archive(_ url: URL) {
        guard let directory else { return }
        let name = "autobot-dpf-samples-" + Self.stamp.string(from: Date()) + ".csv"
        try? FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(name))
    }

    /// Deletes the oldest archived CSVs while all of them together are over AppConfig.DPF.recordMaxTotalBytes.
    private func pruneArchives() {
        var files = csvFiles().filter { $0.lastPathComponent != Self.csvName }
        var total = csvFiles().reduce(0) { $0 + Self.size(of: $1) }
        while total > Tuning.recordMaxTotalBytes, let oldest = files.first {
            total -= Self.size(of: oldest)
            try? FileManager.default.removeItem(at: oldest)
            files.removeFirst()
        }
    }

    /// The CSV files, oldest first (archived ones sort before the current one).
    private func csvFiles() -> [URL] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func updateFiles() {
        let files = csvFiles()
        fileBytes = files.reduce(0) { $0 + Self.size(of: $1) }
        let info = exportFiles.first { $0.lastPathComponent == Self.infoName }
        exportFiles = files + [info].compactMap { $0 }
    }

    /// Writes the info JSON and lists everything to share.
    private func refreshExport() {
        let info = writeInfo()
        exportFiles = csvFiles() + [info].compactMap { $0 }
    }

    private func saveState() {
        guard persist, let url = stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadState(from url: URL?) -> State? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    // MARK: The export's JSON

    private struct Info: Encodable {
        struct Column: Encodable {
            let name: String
            let did: String?
            let tier: String?
            let note: String
        }
        struct Field: Encodable {
            let did: String
            let tier: String
            let columns: [String]
            let note: String
        }
        struct Sweep: Encodable {
            let ranges: [String]
            let perSample: Int
            let answered: [String: String]
            let notThere: [String]
        }
        struct PCMHistory: Encodable {
            let learned: String?
            let confirmed: Bool?
            let kmNewestFirst: [Double]?
            let raw: String?
            let read: Date?
        }
        let car: String
        let exportedAt: Date
        let timeZone: String
        let csvFiles: [String]
        let notes: [String]
        let columns: [Column]
        let fields: [Field]
        let supportDIDs: [String]
        let idDIDs: [String]
        let drives: [Drive]
        let events: [Event]
        let rateNow: Rate
        let sweep: Sweep
        let regenerationLog: [DPFRegenLog.Entry]
        let pcmHistory: PCMHistory
    }

    private func writeInfo() -> URL? {
        let fieldsByColumn = Dictionary(DPFRecordPlan.fields.flatMap { field in field.columns.map { ($0, field) } },
                                        uniquingKeysWith: { first, _ in first })
        var columns: [Info.Column] = Self.metaNotes.map { Info.Column(name: $0.0, did: nil, tier: nil, note: $0.1) }
        columns += Self.rateNotes.map { Info.Column(name: $0.0, did: nil, tier: nil, note: $0.1) }
        columns += Self.fieldColumns.map { name in
            let field = fieldsByColumn[name]
            return Info.Column(name: name, did: field?.did, tier: field.map { Self.tierName($0.tier) },
                               note: field?.note ?? "")
        }
        columns.append(Info.Column(name: "events", did: nil, tier: nil,
                                   note: "What changed since the previous sample, separated by '; '"))
        columns.append(Info.Column(name: "raw", did: nil, tier: nil,
                                   note: "Every PCM (7E0) reply of this sample, 'DID:HEX' separated by spaces, "
                                   + "data bytes after 62 DID; includes the sweep's DIDs"))
        let fields = DPFRecordPlan.fields.map {
            Info.Field(did: $0.did, tier: Self.tierName($0.tier), columns: $0.columns, note: $0.note)
        }
        let sweep = Info.Sweep(ranges: Tuning.recordSweepRanges.map { Self.didText($0.lowerBound) + "-" + Self.didText($0.upperBound) },
                               perSample: Tuning.recordSweepPerSample,
                               answered: state.sweepAnswered, notThere: state.sweepAbsent.sorted())
        let pcmHistory = Info.PCMHistory(
            learned: history.learned.map { DPFHistoryFinder.title($0.header, $0.did, $0.span) },
            confirmed: history.learned?.confirmed,
            kmNewestFirst: history.history,
            raw: history.historyRaw.map { Self.hex($0) },
            read: history.historyRead)
        let info = Info(car: "Mazda CX-5 2015 (KE) 2.2 SKYACTIV-D, automatic",
                        exportedAt: Date(), timeZone: TimeZone.current.identifier,
                        csvFiles: csvFiles().map(\.lastPathComponent),
                        notes: Self.exportNotes, columns: columns, fields: fields,
                        supportDIDs: DPFRecordPlan.supportDIDs, idDIDs: DPFRecordPlan.idDIDs,
                        drives: state.drives, events: state.events, rateNow: rate, sweep: sweep,
                        regenerationLog: regenLog.entries, pcmHistory: pcmHistory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(info) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.infoName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static let metaNotes: [(String, String)] = [
        ("time", "When the sample started, local time with offset"),
        ("unix", "The same, seconds since 1970"),
        ("drive", "Drive (live data from start to stop), named after when it started"),
        ("sample", "Sample number since the data was last cleared"),
        ("kind", "normal: every 30 s; regen: every 10 s while 0380 bit 0 is on or for 20 min after 0432 went up"),
        ("speed_kmh", "Road speed from live data (PID 0D) when the sample started"),
        ("rpm", "Engine speed, mode 01 PID 0C"),
    ]

    private static let rateNotes: [(String, String)] = [
        ("pm_gen_per_100km_since_regen", "PM_GEN ÷ distance since the last regeneration (0434) × 100, g/L per 100 km"),
        ("pm_gen_per_100km_recent", "PM_GEN growth over the last ~10 km of this cycle (recent_window_km), g/L per 100 km"),
        ("recent_window_km", "Distance the recent rates are over, km"),
        ("pm_gen_per_hour_recent", "PM_GEN growth over the last ~10 min of this drive, g/L per hour"),
        ("pm_acc_dsd_per_100km_recent", "PM_ACC_DSD growth over the same stretch as pm_gen_per_100km_recent"),
        ("km_to_trigger", "km until PM_GEN reaches 5.6 g/L at the recent pace (owner logs: a regeneration starts there with the oil warm)"),
        ("fuel_l_since_regen", "Fuel used since the last regeneration from PID 5E, only when all of it was recorded"),
        ("pm_gen_per_litre", "PM_GEN ÷ fuel_l_since_regen, g/L per litre (owner logs: ~6 g/L per ~17.7 L)"),
    ]

    private static let exportNotes: [String] = [
        """
        Mazda DIDs (04xx, 03xx, DAxx, DD01) and their scaling are community reverse engineering, not Mazda \
        documents; the raw column has every reply so other scalings can be applied (e.g. PM /628 instead of \
        ·100/65536).
        """,
        """
        Research (Nov 2026): 0380 bit 0 is the regeneration REQUEST (drops while stopped), the count 0432 goes up \
        as a regeneration starts, and Autobot's regeneration log took the count going up as the end, so its \
        'after' soot values (16–23 g/L) were probably read during the regeneration. The events show the real order.
        """,
        """
        PM_GEN is modelled from engine speed, intake air amount and injected fuel; PM combustion from the exhaust \
        gas temperature sensors; PM_ACC from the DPF differential pressure and exhaust gas amount (Mazda manual).
        """,
        "Standard PIDs (F4xx) are only asked when the PCM's supported-PID bitmap (drives[].support) lists them.",
        """
        The sweep reads 7E0 DIDs in recordSweepRanges a few per 30 s sample, raw only, to find where this PCM \
        keeps the exhaust temperatures (EXHTEMP1/2), the DPF differential pressure (EXHPRESS_DIF), the exhaust gas \
        amount (EXH_FL) and the injected fuel, whose DIDs aren't published.
        """,
    ]

    // MARK: Helpers

    private static func tierName(_ tier: DPFRecordField.Tier) -> String {
        switch tier {
        case .fast: return "every sample"
        case .normal: return "every 30 s"
        case .slow: return "every 2 min"
        case .once: return "once a drive"
        }
    }

    private static func didText(_ value: Int) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - text.count)) + text
    }

    private static func hex(_ bytes: [UInt8], separator: String = " ") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    /// Printable ASCII of an ID ("SH7M-18881-J"), dots for the rest.
    private static func ascii(_ bytes: [UInt8]) -> String {
        String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }

    /// A number for the CSV: no unit, "." decimals, up to 4 decimals; empty for nothing.
    private static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e12 { return String(format: "%.0f", value) }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
