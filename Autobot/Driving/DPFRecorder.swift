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
//     every sample  RPM, PM_GEN / PM_ACC_DSD / PM_ACC (042D / 044B / 042C), regeneration requests 0380
//                   (forced / automatic), count 0432, distance 0434, the PCM's exhaust flow 0430, DPF
//                   pressure sensor voltage 03DB, exhaust O2 0451, desired injection amount 1411 and air
//                   flow 040C; load, air flow, fuel rate, EGR, exhaust / DPF temperatures, DPF pressure
//                                                                                  (tier .fast)
//     every 30 s    + coolant, oil, MAP, boost, intake shutter, exhaust pressure, injection timing,
//                   torque, rail pressure, pedal, VGT / wastegate, fuel pump suction control valve 042B
//                   and flow 042A / 0431, MAF voltage, EGR position, boost / wastegate solenoids, the
//                   regeneration failure code 0381, EXHTEMP1–3 (22 003C–003E)       (tier .normal)
//                   + the next DIDs of a sweep through 7E0 0300–04FF and DA00–DAFF, raw only, to find what
//                   else this PCM answers
//     every 2 min   + odometer, intake / outside air, barometer, fuel level, run time, charge air, turbo,
//                   oil dilution, DPF light count 0433, injector corrections 098A–098D, community
//                   candidates (0301, 1305, DAAE)                                   (.slow)
//     once a drive  the supported-PID bitmaps 22F400…F4C0 (standard PIDs the PCM leaves out aren't
//                   asked), the PCM's software / calibration IDs, reference torque, injector learning
//                   values 0436–0439, fuel pump / intake shutter / EGR learning, km since the oil change
//                   (.once)
//   Names, bits and scaling of the Mazda DIDs: FORScan Viewer 1.5.31's SKYACTIV-D PCM definitions where it
//   has them (README "DPF data recorder")
//   a few reads at a time between two live-data rounds (AppConfig.DPF.recordJobBudget), so Power Mode,
//   reverse and the turn signals keep working; every go starts with RPM (and the road speed live data last
//   read), and every reply keeps the time it came in, so values from one sample can be lined up afterwards
//   a sample in which the PCM answers nothing at all (ignition off, adapter busy) is a gap: no row, and
//   nothing counts against the values; a value that has answered on this drive is never dropped
//   parked check (DPF screen, user-started): for a few minutes, back-to-back samples of the soot model,
//   air flow, boost, DPF pressure and temperatures (kind "check"), e.g. at a steady 3,000 rpm
//   -> Application Support/DPFRecorder/autobot-dpf-samples.csv: one row per sample — decoded values, the
//      PM_GEN rates, events (request flags, count, distance reset, PM_GEN drop, PM_ACC_DSD jump) and every raw
//      reply ("RPM:812@0.0 SPD:0@0.0 042D:01EF@0.2 …", @ = seconds after the sample's time) in the last
//      column
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
        field("044B", .fast, ["pm_acc_dsd"], """
              PM_ACC_DSD: PM accumulation amount desired, (A·256+B)·100/65536 g/L (FORScan: /65535). Mazda's \
              DTC P243C test: at a steady 3,000 rpm, twice PM_GEN or more points at the DPF pressure sensor. (Before \
              Nov 2026 this column was 042B, which is the fuel pump's suction control valve: fip_scv_a)
              """) {
            [MazdaDPF.soot($0)]
        },
        field("042C", .fast, ["pm_acc"],
              "PM_ACC: accumulated PM. (A·256+B)·100/65536 g/L (community)") {
            [MazdaDPF.soot($0)]
        },
        field("0380", .fast, ["regen_req", "regen_forced", "regen_auto"], """
              Regeneration requests, byte A: raw value, bit 0 REG_REQ_F (forced), bit 1 REG_REQ_A (automatic) \
              (FORScan's PCM definitions; they drop while stopped although the regeneration carries on)
              """) { d in
            [byte(d, 0), byte(d, 0).map { Double(Int($0) & 0x01) }, byte(d, 0).map { Double(Int($0) >> 1 & 0x01) }]
        },
        field("0432", .fast, ["regen_count"], """
              Regeneration count A·256+B. On this car it goes up as one ENDS: PM_ACC was already at 0–1 g/L \
              every time (regeneration log 280–286)
              """) {
            [MazdaDPF.regenCount($0).map { Double($0) }]
        },
        field("0434", .fast, ["regen_km"], """
              Distance since the last regeneration (REG_DIS): the whole value ·100/64000 km (FORScan). CSV files \
              from before Nov 2026 used (B·65536+C·256+D)·100/65536, 2.4 % less (×1.024 to compare)
              """) {
            [MazdaDPF.regenDistance($0)]
        },
        // The PCM's own soot-model inputs (FORScan's SKYACTIV-D PCM definitions).
        field("0430", .fast, ["exh_flow"], """
              EXH_FL: exhaust gas flow amount, (A·256+B)·100/65535 (FORScan's label says mm3/min; ~0.3 at idle \
              and ~5 at 50 km/h fit m³/min). With the DPF pressure it gives PM_ACC
              """) {
            [word($0, 0).map { $0 * 100 / 65535 }]
        },
        field("03DB", .fast, ["dpf_dp_sensor_v"],
              "EXHPRESS_DIF: DPF differential pressure sensor voltage, (A·256+B)·5/1024 V") {
            [word($0, 0).map { $0 * 5 / 1024 }]
        },
        field("0451", .fast, ["exh_o2_pct"], "O2: oxygen in the exhaust gas, A/10 % (about 21–23 with the fuel cut)") {
            [byte($0, 0).map { $0 / 10 }]
        },
        field("1411", .fast, ["fuel_inj_dsd_mm3"], "FIA_DSD: fuel injection amount desired, (A·256+B)/16 mm³/stroke") {
            [word($0, 0).map { $0 / 16 }]
        },
        field("040C", .fast, ["maf_dsd_gs"], "MAF_DSD: mass air flow desired (the EGR target), (A·256+B)/100 g/s") {
            [word($0, 0).map { $0 / 100 }]
        },
        // What the soot model works from, as standard PIDs (where this PCM supports them).
        field("F404", .fast, ["load_pct"], "PID 04 calculated load A·100/255 %") {
            [percent(byte($0, 0))]
        },
        field("F410", .fast, ["maf_gs"], """
              PID 10 mass air flow (A·256+B)/100 g/s as the standard has it; this PCM reads ~3.75× lower than \
              PID 66 (its own scale: see maf_max_gs, PID 50)
              """) {
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
        field("F40B", .normal, ["map_kpa"], """
              PID 0B intake manifold absolute pressure, A·10 kPa on this PCM (11 = 110 kPa, the same as PID 70's \
              actual boost; PID 4F sets the scale)
              """) {
            [byte($0, 0).map { $0 * 10 }]
        },
        field("F470", .normal, ["boost_target_kpa", "boost_kpa"],
              "PID 70 boost commanded (B·256+C)/32, actual (D·256+E)/32 kPa abs", multiFrame: true) { d in
            let boost = MazdaDPF.boost(d)
            return [boost.target, boost.actual]
        },
        field("F411", .normal, ["isv_pct"], "PID 11 throttle (intake shutter valve) position A·100/255 %") {
            [percent(byte($0, 0))]
        },
        field("F46C", .normal, ["isv_cmd_pct", "isv_rel_pct"], """
              PID 6C intake shutter (throttle actuator A): commanded B / relative position C ·100/255 %
              """, multiFrame: true) { d in
            [flagged(d, 0x01, percent(byte(d, 1))), flagged(d, 0x02, percent(byte(d, 2)))]
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
        field("F459", .normal, ["rail_abs_kpa"], "PID 59 fuel rail absolute pressure (A·256+B)·10 kPa") {
            [word($0, 0).map { $0 * 10 }]
        },
        field("F46D", .normal, ["rail_cmd_kpa", "rail_act_kpa"],
              "PID 6D fuel pressure control: commanded (B·256+C)·10, actual (D·256+E)·10 kPa", multiFrame: true) { d in
            [flagged(d, 0x01, word(d, 1).map { $0 * 10 }), flagged(d, 0x02, word(d, 3).map { $0 * 10 })]
        },
        field("F449", .normal, ["pedal_pct"], "PID 49 accelerator pedal position D A·100/255 %") {
            [percent(byte($0, 0))]
        },
        // Fuel pump, air and turbo control (FORScan's SKYACTIV-D PCM definitions).
        field("042B", .normal, ["fip_scv_a"], """
              FIP_SCV: fuel pump suction control valve current, (A·256+B)/8000 A (higher at idle, lower under load). \
              Community lists called it PM_ACC_DSD
              """) {
            [word($0, 0).map { $0 / 8000 }]
        },
        field("042A", .normal, ["fip_fl_a"], "FIP_FL: fuel pump flow control, (A·256+B)/8000 A") {
            [word($0, 0).map { $0 / 8000 }]
        },
        field("0431", .normal, ["fip_fl_dsd"], "FIP_FL_DSD: fuel pump flow desired, (A·256+B − 10200)·5/255 (FORScan: mm³/stroke)") {
            [word($0, 0).map { ($0 - 10200) * 5 / 255 }]
        },
        field("0314", .normal, ["maf_v"], "MAF_V: mass air flow sensor voltage, (A·256+B)/1024 V") {
            [word($0, 0).map { $0 / 1024 }]
        },
        field("03FB", .normal, ["egr_pos_pct"], "EGRP: EGR valve position A·100/255 %") {
            [percent(byte($0, 0))]
        },
        field("03DF", .normal, ["vbc_sol_pct"], "VBCV: variable boost control solenoid, (A·256+B)·100/65535 %") {
            [word($0, 0).map { $0 * 100 / 65535 }]
        },
        field("0462", .normal, ["wgc_sol_pct"], "WGC: wastegate control solenoid, (A·256+B)·100/32768 %") {
            [word($0, 0).map { $0 * 100 / 32768 }]
        },
        field("046E", .normal, ["wg_pos_v"], "WG_POS: wastegate position sensor, (A·256+B)·5/1024 V") {
            [word($0, 0).map { $0 * 5 / 1024 }]
        },
        field("0307", .normal, ["fuel_pump_duty_pct"], "FP_DUTY: fuel pump duty, (A·256+B)·100/32768 %") {
            [word($0, 0).map { $0 * 100 / 32768 }]
        },
        field("0308", .normal, ["rpm_desired"], "ARPMDES: desired (idle) RPM, A·256+B") {
            [word($0, 0)]
        },
        field("044A", .normal, ["o2_mode"], "O2S11_MODE: oxygen sensor activation status (3 = active, 0 = not yet)") {
            [byte($0, 0)]
        },
        field("0381", .normal, ["regen_fail_code"], """
              REG_FAIL_C: DPF regeneration failure condition, byte A bits: 01 timeout, 04 vehicle moving (VSS_DET), \
              08 coolant too hot, 10 coolant too cold (FORScan)
              """) {
            [byte($0, 0)]
        },
        // Fuel in the oil (EngineHealth): the PCM's own estimate and the oil pressure that fuel thins.
        field("03E1", .normal, ["oil_dilution_raw", "oil_dilution_g"], """
              OIL_DIL: the PCM's estimate of fuel in the oil, raw A·256+B and FORScan's (A·256+B)·100000/65535 g \
              (Mazda's tool shows it in kg; Mazda sets P252F at 1,661 g and P253F at 2,236 g; it resets with the \
              engine oil data reset). Before Nov 2026 every 2 min, oil_dilution
              """) {
            [word($0, 0), word($0, 0).map { $0 * 100000 / 65535 }]
        },
        field("0415", .normal, ["oil_pressure_kpa"], """
              EOP: engine oil pressure, A·256+B kPa (FORScan's definition from other Mazda PCMs; this PCM answers \
              it). Mazda: about 184 kPa at a warm idle; 140–190 kPa at 1,500 rpm and 310–450 kPa at 3,500 rpm with \
              the oil at 70–80 °C; P253F when it is 40 kPa below its value after the oil change (1,500 rpm, oil 87–88 °C)
              """) {
            [word($0, 0)]
        },
        field("0424", .normal, ["oil_pressure_sensor_v"], """
              EOP_V: oil pressure sensor voltage, (A·256+B)/1024 V (FORScan's definition from other Mazda PCMs)
              """) {
            [word($0, 0).map { $0 / 1024 }]
        },
        field("0594", .normal, ["oil_pump_duty_pct"], """
              OIL_P_DUTY: oil pressure control (variable oil pump) duty, (A·256+B)·100/32768 % (Mazda: about 55 % at \
              idle, 0 % above 4,000 rpm)
              """) {
            [word($0, 0).map { $0 * 100 / 32768 }]
        },
        field("003C", .normal, ["exhtemp1_c"], "EXHTEMP1 (upper), 22 003C: (A·256+B)/10 − 40 °C") {
            [word($0, 0).map { $0 / 10 - 40 }]
        },
        field("003D", .normal, ["exhtemp2_c"], "EXHTEMP2 (middle), 22 003D: (A·256+B)/10 − 40 °C") {
            [word($0, 0).map { $0 / 10 - 40 }]
        },
        field("003E", .normal, ["exhtemp3_c"], "EXHTEMP3 (lower), 22 003E: (A·256+B)/10 − 40 °C") {
            [word($0, 0).map { $0 / 10 - 40 }]
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
        field("DD01", .slow, ["odometer_km", "odometer_shown_km"], """
              Odometer A·65536+B·256+C km as the cluster shows it (odometer_shown_km); odometer_km is the true \
              distance, + AppConfig.Odometer.offsetKm (\(Int(AppConfig.Odometer.offsetKm)) km: this car's \
              odometer was adjusted)
              """) {
            [MazdaDPF.odometer($0), MazdaDPF.odometerShown($0)]
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
        raw("F467", .slow, "PID 67 coolant temperature sensors (raw)", multiFrame: true),
        raw("F468", .slow, "PID 68 intake air temperature sensors (raw)", multiFrame: true),
        field("F442", .slow, ["module_v"], "PID 42 control module voltage (A·256+B)/1000 V") {
            [word($0, 0).map { $0 / 1000 }]
        },
        field("F401", .slow, ["mil_on", "dtc_count"], """
              PID 01 monitor status: A bit 7 = check-engine light on, A bits 0–6 = emissions DTCs stored
              """) {
            [byte($0, 0).map { Double(Int($0) >> 7) }, byte($0, 0).map { Double(Int($0) & 0x7F) }]
        },
        raw("F48B", .slow, "PID 8B diesel aftertreatment status (raw; not answered on the 2015 KE so far)",
            multiFrame: true),
        field("0433", .slow, ["dpf_lamp_count"], "DPF_LMP_CNT: times the DPF light has come on, A·256+B") {
            [word($0, 0)]
        },
        field("098A", .slow, ["inj1_cmp_mm3"], "INJ1_CMP: injector 1 correction, signed 32-bit /131072 mm³/stroke") {
            [signed32($0, 0).map { $0 / 131072 }]
        },
        field("098B", .slow, ["inj2_cmp_mm3"], "INJ2_CMP: injector 2 correction, signed 32-bit /131072 mm³/stroke") {
            [signed32($0, 0).map { $0 / 131072 }]
        },
        field("098C", .slow, ["inj3_cmp_mm3"], "INJ3_CMP: injector 3 correction, signed 32-bit /131072 mm³/stroke") {
            [signed32($0, 0).map { $0 / 131072 }]
        },
        field("098D", .slow, ["inj4_cmp_mm3"], "INJ4_CMP: injector 4 correction, signed 32-bit /131072 mm³/stroke") {
            [signed32($0, 0).map { $0 / 131072 }]
        },
        field("0435", .slow, ["oil_dilution_events"], """
              OIL_DIL_CNT: times the PCM judged the engine oil deteriorated (FORScan), A
              """) {
            [byte($0, 0)]
        },
        field("0416", .slow, ["low_oil_pressure_sw"], """
              LOW_OIL: low oil pressure switch / oil level status, bit 9 of A–D (0 = never detected; FORScan, other \
              Mazda PCMs)
              """) { d in
            [unsigned32(d, 0).map { Double(Int($0) >> 9 & 1) }]
        },
        field("DA01", .slow, ["oil_pressure_sol"], "OIL_P_SOL: oil pressure solenoid valve, bit 1 of A (FORScan)") {
            [byte($0, 0).map { Double(Int($0) >> 1 & 1) }]
        },
        // Community candidates, unconfirmed on this PCM: raw only, to compare with the rest afterwards.
        raw("0301", .slow, "MAP sensor voltage (A·256+B)/1000 V? (one list)"),
        raw("1305", .slow, "Target boost ((A·256+B)/64)/100 bar? (one list)"),
        raw("DAAE", .slow, "Fuel injection amount learning: count / distance? (one list)", multiFrame: true),
        // Once a drive.
        field("F463", .once, ["torque_ref_nm"], "PID 63 engine reference torque A·256+B Nm") {
            [word($0, 0)]
        },
        field("F44F", .once, ["map_max_kpa"], "PID 4F maximum values: D·10 = the top of PID 0B's MAP scale, kPa") {
            [byte($0, 3).map { $0 * 10 }]
        },
        field("F450", .once, ["maf_max_gs"], "PID 50 maximum air flow: A·10 = the top of PID 10's MAF scale, g/s") {
            [byte($0, 0).map { $0 * 10 }]
        },
        field("F431", .once, ["km_since_codes_cleared"], "PID 31 distance since the trouble codes were cleared, km") {
            [word($0, 0)]
        },
        field("F430", .once, ["warmups_since_cleared"], "PID 30 warm-ups since the trouble codes were cleared") {
            [byte($0, 0)]
        },
        field("F421", .once, ["km_with_mil"], "PID 21 distance driven with the check-engine light on, km") {
            [word($0, 0)]
        },
        // Learned values (FORScan's SKYACTIV-D PCM definitions): injector learning at 4 rail pressures, (byte − 128)·4 µs.
        injectorLearning("0436", 35),
        injectorLearning("0437", 65),
        injectorLearning("0438", 100),
        injectorLearning("0439", 140),
        field("051A", .once, ["fip_lrn_status"], "FIP_LRN: fuel pump learning status (0 not learned, 1 temporary, 2 complete)") {
            [byte($0, 0)]
        },
        field("051E", .once, ["fip_lrn"], "FIP_LRN: fuel pump learning amount, (A·256+B)/1000") {
            [word($0, 0).map { $0 / 1000 }]
        },
        field("0534", .once, ["isv_lrn_closed"], "ISV_LRN_C: intake shutter learned closed position, (A·256+B − 32768)·200/65535") {
            [word($0, 0).map { ($0 - 32768) * 200 / 65535 }]
        },
        field("0538", .once, ["egr_lrn_closed_mm"], "EGR_LRN: EGR valve learned closed position, (A·256+B − 32768)·200/65535 mm") {
            [word($0, 0).map { ($0 - 32768) * 200 / 65535 }]
        },
        field("0519", .once, ["oil_change_km"], "OILCHG_DIS: distance since the last oil change, (A·256+B)·4 km") {
            [word($0, 0).map { $0 * 4 }]
        },
        field("0542", .once, ["oil_change_km2"], "OILCHG_DIS2: distance since the last oil change 2 (correction value), A·256+B") {
            [word($0, 0)]
        },
        field("DD00", .once, ["total_time"], "TOTAL_TIME: total time the PCM has run, (32-bit)/10 (unit not confirmed)") {
            [unsigned32($0, 0).map { $0 / 10 }]
        },
        raw("C968", .once, "INJ_LRN_F1: injector learning mode failure code 1 (raw)"),
        raw("C969", .once, "INJ_LRN_F2: injector learning mode failure code 2 (raw)"),
    ]

    /// Read in a parked check, back to back (AppConfig.DPF.recordCheck…): the soot model and what its
    /// pressure / air numbers depend on at a fixed engine speed.
    static let checkDIDs: Set<String> = [
        "042D", "044B", "042C", "0380", "0432", "0434", "0430", "03DB", "0451", "1411", "040C", "F404", "F466",
        "F470", "F40B", "F47A", "F478", "F469", "F411", "F46C", "F405", "F45C", "F423", "F46D", "F45D", "F473",
        "042B", "0415",
    ]

    /// Refusals (7F 22 xx) meaning the DID isn't there (or not without security access). Others (busy,
    /// conditions not correct…) are taken like no reply.
    static let absentCodes: Set<UInt8> = [0x11, 0x12, 0x31, 0x33, 0x7E, 0x7F]

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

    /// Big-endian 32-bit value at `index`, unsigned / signed.
    private static func unsigned32(_ data: [UInt8], _ index: Int) -> Double? {
        guard index + 3 < data.count else { return nil }
        let value = UInt32(data[index]) << 24 | UInt32(data[index + 1]) << 16 | UInt32(data[index + 2]) << 8
            | UInt32(data[index + 3])
        return Double(value)
    }

    private static func signed32(_ data: [UInt8], _ index: Int) -> Double? {
        unsigned32(data, index).map { Double(Int32(bitPattern: UInt32($0))) }
    }

    /// FI_LRN: the 4 injectors' learned corrections at one rail pressure (0436 35 MPa … 0439 140 MPa), one
    /// byte each (A = injector 1), (byte − 128)·4 µs.
    private static func injectorLearning(_ did: String, _ mpa: Int) -> DPFRecordField {
        let columns = (1...4).map { "inj\($0)_lrn\(mpa)_us" }
        return field(did, .once, columns, "FI_LRN: injector learning values at \(mpa) MPa, injectors 1–4, (byte − 128)·4 µs") { d in
            (0..<4).map { index in byte(d, index).map { ($0 - 128) * 4 } }
        }
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

    /// How fast PM_GEN grows (and how 042B moved), worked out after every sample.
    struct Rate: Codable, Equatable {
        /// PM_GEN per 100 km since the last regeneration (PM_GEN ÷ distance since it), g/L.
        var sinceRegen: Double?
        /// PM_GEN per 100 km over the last ~rateWindowKm of this regeneration cycle, g/L…
        var recent: Double?
        /// …over this many km.
        var recentKm: Double?
        /// PM_GEN per hour over the last ~rateWindowMinutes of this drive, g/L.
        var perHour: Double?
        /// 042B's change per 100 km over the same stretch as `recent` (it follows load: not a growth rate).
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
    /// The parked check (DPF screen): until when it runs, its samples so far, the latest sample's values
    /// (CSV column names, plus "rpm"), and how the last one ended.
    @Published private(set) var checkEnds: Date?
    @Published private(set) var checkSamples = 0
    @Published private(set) var checkValues: [String: Double] = [:]
    @Published private(set) var checkNote = ""

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
        /// Where the re-asking of the DIDs found not there has got to (optional: older state.json files
        /// don't have it, and a missing non-optional key would make the whole file unreadable).
        var sweepRecheckCursor: Int?
        /// The scale cycle[].regenKm and last.regenKm are in (220434 units per 100 km); nil: saved before Nov
        /// 2026, in the community ·100/65536 (optional, like sweepRecheckCursor).
        var regenUnitsPer100Km: Double?
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
        /// When it came in.
        let time: Date
    }

    /// RPM, and the road speed live data last read, at the start of a go.
    private struct Mark {
        let time: Date
        let rpm: Double?
        let speed: Double?
    }

    private struct Chunk {
        var marks: [Mark] = []
        var replies: [Reply] = []
        /// The first go's RPM: the sample's `rpm` column.
        var rpm: Double? { marks.first(where: { $0.rpm != nil })?.rpm }
    }

    private let obd: OBDAdapter
    private let regenLog: DPFRegenLog
    private let history: DPFHistoryFinder
    /// The engine health watch, fed with every sample (shown on the DPF screen, in the export).
    let health: EngineHealth
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
    /// Fields that have answered on this drive (a silence later is a gap, never a reason to drop them), and
    /// fields that haven't answered a few times in a row (asked again every 2 min).
    private var answeredThisDrive: Set<String> = []
    private var silentSkipped: Set<String> = []
    /// The PCM answered nothing in the last sample (ignition off, adapter busy).
    private var inGap = false
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
        health = EngineHealth(persist: recording, regenEntries: regenLog.entries)
        directory = recording ? DPFRecorder.makeDirectory() : nil
        if persist {
            state = Self.loadState(from: stateURL) ?? State()
            // 0434 is read in FORScan's scale since Nov 2026: the cycle's distances saved in the one before are
            // converted, so the rates don't jump.
            let savedUnits = state.regenUnitsPer100Km ?? MazdaDPF.regenDistanceUnitsPer100KmBefore
            if savedUnits != MazdaDPF.regenDistanceUnitsPer100Km {
                let factor = savedUnits / MazdaDPF.regenDistanceUnitsPer100Km
                for i in state.cycle.indices { state.cycle[i].regenKm *= factor }
                if let km = state.last?.regenKm { state.last?.regenKm = km * factor }
            }
            state.regenUnitsPer100Km = MazdaDPF.regenDistanceUnitsPer100Km
            // DIDs that are fields now (FORScan's names, Nov 2026) leave the sweep's lists.
            let fieldDIDs = Set(DPFRecordPlan.fields.map(\.did))
            state.sweepAnswered = state.sweepAnswered.filter { !fieldDIDs.contains($0.key) }
            state.sweepAbsent.subtract(fieldDIDs)
            prepareCSV()
        }
        health.onLog = { [weak self] message in self?.onLog?(message) }
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
        health.refresh(regenEntries: regenLog.entries)
        refreshExport()
    }

    func screenClosed() {
        screenOpen = false
    }

    /// Starts the parked check: back-to-back samples of AppConfig.DPF.recordCheck… for a few minutes.
    func startCheck() {
        guard isRecording else {
            checkNote = "Live data isn't running: start the engine with the adapter connected."
            return
        }
        if let speed = obd.sample?.speed, speed > Tuning.recordCheckMaxSpeed {
            checkNote = "Park first: the check is for a car standing still."
            return
        }
        checkEnds = Date().addingTimeInterval(Tuning.recordCheckDuration)
        checkSamples = 0
        checkValues = [:]
        checkNote = ""
        onLog?(String(format: "DPF recorder: parked check started (%.0f min)", Tuning.recordCheckDuration / 60))
    }

    /// The Stop button.
    func stopCheck() {
        endCheck("Stopped after \(checkSamples) samples.")
    }

    /// Ends the parked check: stopped, done, the car moved, or live data stopped.
    private func endCheck(_ note: String) {
        guard checkEnds != nil else { return }
        checkEnds = nil
        checkNote = note
        onLog?("DPF recorder: parked check ended · \(checkSamples) samples")
        if screenOpen { refreshExport() }
    }

    /// Deletes the recorded samples, drives and events. What the sweep found about the PCM is kept.
    func clear() {
        for url in csvFiles() { try? FileManager.default.removeItem(at: url) }
        var fresh = State()
        fresh.sweepAbsent = state.sweepAbsent
        fresh.sweepSilent = state.sweepSilent
        fresh.sweepCursor = state.sweepCursor
        fresh.sweepAnswered = state.sweepAnswered
        fresh.sweepRecheckCursor = state.sweepRecheckCursor
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
        answeredThisDrive = []
        silentSkipped = []
        inGap = false
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
        endCheck("Stopped: live data stopped.")
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
            let checking = checkEnds != nil
            let fast = isFast(at: started)
            await sample(fast: fast, check: checking, at: started)
            guard !Task.isCancelled else { return }
            let interval = checkEnds != nil ? Tuning.recordCheckInterval
                : (fast ? Tuning.recordIntervalDuringRegen : Tuning.recordInterval)
            // In short steps, so that a parked check starts at once.
            let wakeAt = started.addingTimeInterval(interval)
            while !Task.isCancelled, Date() < wakeAt {
                if !checking, checkEnds != nil { break }
                try? await Task.sleep(for: .seconds(min(1, max(0.05, wakeAt.timeIntervalSinceNow))))
            }
        }
    }

    /// Every 10 s while the request flag is on, or for a while after the count went up.
    private func isFast(at date: Date) -> Bool {
        if let request = state.last?.regenReq, request & Int(MazdaDPF.regenStatusMask) != 0 { return true }
        if let until = state.fastUntil, date < until { return true }
        return false
    }

    private func sample(fast: Bool, check requested: Bool, at started: Date) async {
        guard drive != nil else { return }
        if !driveInfoRead {
            guard await readDriveInfo() else { return }          // live data stopped meanwhile
        }
        guard let driveID = drive?.id else { return }
        let speed = obd.sample?.speed
        var check = requested
        if check, let ends = checkEnds {
            if started >= ends {
                endCheck("Done: \(checkSamples) samples. Export to send them.")
                check = false
            } else if let speed, speed > Tuning.recordCheckMaxSpeed {
                endCheck("Stopped: the car moved.")
                check = false
            }
        }
        // While the PCM is silent (ignition off?), one read per sample to see whether it's back.
        if inGap {
            guard let probe = await readAll([.did("042D", multiFrame: false, sweep: false)]),
                  Self.anyAnswer(probe.0) else { return }
            inGap = false
            onLog?("DPF recorder: the PCM is answering again")
        }
        let normal = !check && (lastNormal.map { started.timeIntervalSince($0) >= Tuning.recordInterval - 1 } ?? true)
        let slow = !check && (lastSlow.map { started.timeIntervalSince($0) >= Tuning.recordSlowInterval - 1 } ?? true)
        var reads: [Read] = []
        for field in DPFRecordPlan.fields where wanted(field, normal: normal, slow: slow, check: check) {
            reads.append(.did(field.did, multiFrame: field.multiFrame, sweep: false))
        }
        let sweep = normal ? nextSweep(Tuning.recordSweepPerSample) : []
        reads += sweep.map { Read.did($0, multiFrame: false, sweep: true) }

        let budget = check ? Tuning.recordCheckJobBudget : Tuning.recordJobBudget
        guard let (chunk, cut) = await readAll(reads, budget: budget) else { return }

        // Nothing at all from the PCM (ignition off, adapter busy): a gap. Nothing counts against the
        // values, and no row is written.
        guard Self.anyAnswer(chunk) else {
            inGap = true
            onLog?("DPF recorder: the PCM isn't answering (ignition off?), waiting")
            status = "Waiting: the PCM isn't answering"
            saveState()
            return
        }
        if normal { lastNormal = started }
        if slow { lastSlow = started }
        if !check {
            for field in DPFRecordPlan.fields where field.tier == .once { onceDone.insert(field.did) }
        }

        // What came back, each with when it came in ("@1.4" = 1.4 s after the sample's time).
        var data: [String: [UInt8]] = [:]
        var rawParts: [String] = []
        for mark in chunk.marks {
            let at = Self.offset(mark.time, from: started)
            rawParts.append("RPM:" + Self.format(mark.rpm) + at)
            if let speed = mark.speed { rawParts.append("SPD:" + Self.format(speed) + at) }
        }
        var newlySkipped: [String] = []
        for item in chunk.replies {
            switch item.reply {
            case .data(let bytes):
                data[item.did] = bytes
                rawParts.append(item.did + ":" + Self.hex(bytes, separator: "") + Self.offset(item.time, from: started))
                if item.sweep {
                    state.sweepAnswered[item.did] = Self.hex(bytes)
                    state.sweepSilent[item.did] = nil
                    state.sweepAbsent.remove(item.did)
                } else {
                    misses[item.did] = 0
                    answeredThisDrive.insert(item.did)
                    if silentSkipped.remove(item.did) != nil {
                        updateDrive { $0.notAnswered[item.did] = nil }
                    }
                }
            case .refused(let code):
                let why = String(format: "7F 22 %02X ", code) + ELM327.negativeResponseName(code)
                let permanent = DPFRecordPlan.absentCodes.contains(code)
                if item.sweep {
                    if permanent { markAbsent(item.did) } else { sweepSilence(item.did) }
                } else if permanent {
                    skip(item.did, why: why)
                    newlySkipped.append(item.did)
                } else if fieldSilence(item.did, why: why) {
                    newlySkipped.append(item.did)
                }
            case .silent:
                if item.sweep {
                    sweepSilence(item.did)
                } else if fieldSilence(item.did, why: "no reply") {
                    newlySkipped.append(item.did)
                }
            }
        }
        if !newlySkipped.isEmpty {
            onLog?("DPF recorder: not answered, asked less often or not again this drive: " + newlySkipped.joined(separator: ", "))
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
        let pmAcc = values["pm_acc"]
        let fuelRate = values["fuel_rate_lh"]

        state.sampleNumber += 1
        let number = state.sampleNumber
        var events = changes(request: request, count: count, regenKm: regenKm, pmGen: pmGen, pmDsd: pmDsd,
                             at: started)
        if driveSamples == 0 { events.insert("drive start", at: 0) }
        if cut { events.append("cut short: live data stopped") }
        updateCycle(at: started, drive: driveID, regenKm: regenKm, pmGen: pmGen, pmDsd: pmDsd, fuelRate: fuelRate)
        let newRate = makeRate(at: started, drive: driveID, pmGen: pmGen, pmDsd: pmDsd, regenKm: regenKm)
        health.observe(values, rpm: chunk.rpm, speed: speed, at: started, drive: driveID,
                       pmGenPer100Km: (newRate.regenKm ?? 0) >= Tuning.pmGenVerdictMinKm ? newRate.sinceRegen : nil,
                       regenEntries: regenLog.entries)

        // The row.
        var cells: [String] = [
            Self.isoTime.string(from: started),
            String(format: "%.0f", started.timeIntervalSince1970),
            driveID,
            String(number),
            check ? "check" : (fast ? "regen" : "normal"),
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
            if let pmAcc { line += String(format: " · PM_ACC %.2f", pmAcc) }
            if let regenKm { line += String(format: " · %.1f km", regenKm) }
            if let oil = values["oil_c"] { line += String(format: " · oil %.0f °C", oil) }
            onLog?(line)
        }
        updateDrive { $0.samples += 1 }
        driveSamples += 1
        sampleCount = number
        lastSample = started
        rate = newRate
        if check {
            checkSamples += 1
            var shown = values
            if let rpm = chunk.rpm { shown["rpm"] = rpm }
            checkValues = shown
            status = "Parked check: every value back to back"
        } else {
            status = String(format: fast ? "Recording every %.0f s (regeneration)" : "Recording every %.0f s",
                            fast ? Tuning.recordIntervalDuringRegen : Tuning.recordInterval)
        }
        saveState()
        if screenOpen { refreshExport() }
    }

    /// Reads everything in short gos between two live-data rounds, each at most `budget` (a single-frame read
    /// counts 1, one read to the end of several frames 3) and each starting with RPM. nil if live data
    /// stopped before anything was read; `cut` if it stopped part-way.
    private func readAll(_ reads: [Read], budget: Int = Tuning.recordJobBudget) async -> (Chunk, cut: Bool)? {
        var result = Chunk()
        var index = 0
        while index < reads.count {
            let first = index
            var part: [Read] = [.rpm]
            var cost = Self.cost(of: Read.rpm)
            while index < reads.count {
                let next = Self.cost(of: reads[index])
                if part.count > 1, cost + next > budget { break }
                part.append(reads[index])
                cost += next
                index += 1
            }
            let toRead = part
            guard !Task.isCancelled,
                  let chunk = await obd.runBetweenRounds({ adapter in await Self.read(toRead, with: adapter) }) else {
                return first == 0 ? nil : (result, true)
            }
            result.marks += chunk.marks
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
                let speed = adapter.sample?.speed
                let rpm = await adapter.readRPM()
                chunk.marks.append(Mark(time: Date(), rpm: rpm, speed: speed))
            case .did(let did, let multiFrame, let sweep):
                let reply = await adapter.probeDID(did, from: MazdaDPF.header, complete: multiFrame,
                                                   timeout: sweep ? Tuning.recordSweepTimeout : AppConfig.OBD.replyTimeout)
                chunk.replies.append(Reply(did: did, sweep: sweep, reply: reply, time: Date()))
            }
        }
        return chunk
    }

    /// "@1.4": seconds after the sample's time, for the raw column.
    private static func offset(_ time: Date, from start: Date) -> String {
        "@" + String(format: "%.1f", max(0, time.timeIntervalSince(start)))
    }

    /// Whether the PCM answered anything in `chunk`, data or a refusal.
    private static func anyAnswer(_ chunk: Chunk) -> Bool {
        chunk.replies.contains { item in
            if case .silent = item.reply { return false }
            return true
        }
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

    /// Whether to read `field` in this sample. In a parked check only the check's DIDs; a field that hasn't
    /// answered a few times in a row only every 2 min.
    private func wanted(_ field: DPFRecordField, normal: Bool, slow: Bool, check: Bool) -> Bool {
        guard !skipped.contains(field.did) else { return false }
        if let pid = field.standardPID, supports(pid) == false { return false }
        if silentSkipped.contains(field.did) { return slow }
        if check { return DPFRecordPlan.checkDIDs.contains(field.did) }
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

    /// Not asked again this drive: the PCM said it doesn't have it.
    private func skip(_ did: String, why: String) {
        skipped.insert(did)
        updateDrive { $0.notAnswered[did] = why }
    }

    /// A field the PCM didn't answer, counted only while it hasn't answered on this drive; after a few in
    /// a row it's asked every 2 min only. True when it was just moved to that.
    private func fieldSilence(_ did: String, why: String) -> Bool {
        guard !answeredThisDrive.contains(did), !silentSkipped.contains(did) else { return false }
        let count = (misses[did] ?? 0) + 1
        misses[did] = count
        guard count >= Tuning.missesBeforeSkipping else { return false }
        silentSkipped.insert(did)
        updateDrive { $0.notAnswered[did] = why + " (asked every 2 min)" }
        return true
    }

    // MARK: The sweep

    /// The next `count` DIDs of the sweep that may exist (the cursor moves on), plus a few of the ones
    /// found not there, asked again in turn (AppConfig.DPF.recordSweepRecheck).
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
        let absent = all.filter { state.sweepAbsent.contains($0) }
        if !absent.isEmpty, Tuning.recordSweepRecheck > 0 {
            var recheck = (state.sweepRecheckCursor ?? 0) % absent.count
            for _ in 0..<min(Tuning.recordSweepRecheck, absent.count) {
                picked.append(absent[recheck])
                recheck = (recheck + 1) % absent.count
            }
            state.sweepRecheckCursor = recheck
        }
        return picked
    }

    /// A sweep DID that didn't answer (or was refused with "busy" and the like): counted only for DIDs that
    /// never have answered; twice -> not there (asked again now and then by the recheck).
    private func sweepSilence(_ did: String) {
        guard state.sweepAnswered[did] == nil, !state.sweepAbsent.contains(did) else { return }
        let count = (state.sweepSilent[did] ?? 0) + 1
        state.sweepSilent[did] = count
        if count >= 2 { markAbsent(did) }
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
    /// PM_ACC_DSD (044B) jumping.
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
        /// AppConfig.Odometer.offsetKm: odometer_km = odometer_shown_km + this.
        let odometerOffsetKm: Double
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
        let engineHealth: EngineHealth.Export
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
                                   note: "Every PCM (7E0) reply of this sample, 'DID:HEX@t' separated by spaces: "
                                   + "data bytes after 62 DID, t = seconds after the sample's time; 'RPM:x@t' and "
                                   + "'SPD:x@t' (km/h) at the start of every go; includes the sweep's DIDs"))
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
                        odometerOffsetKm: AppConfig.Odometer.offsetKm,
                        csvFiles: csvFiles().map(\.lastPathComponent),
                        notes: Self.exportNotes, columns: columns, fields: fields,
                        supportDIDs: DPFRecordPlan.supportDIDs, idDIDs: DPFRecordPlan.idDIDs,
                        drives: state.drives, events: state.events, rateNow: rate, sweep: sweep,
                        regenerationLog: regenLog.entries, pcmHistory: pcmHistory, engineHealth: health.export)
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
        ("kind", "normal: every 30 s; regen: every 10 s while a 0380 request bit (0 forced, 1 automatic) is on or for 20 min after 0432 went up; check: the parked check, back to back"),
        ("speed_kmh", "Road speed from live data (PID 0D) when the sample started"),
        ("rpm", "Engine speed (mode 01 PID 0C) at the start of the sample's first go; every go's RPM and road speed are in raw (RPM:…@t SPD:…@t)"),
    ]

    private static let rateNotes: [(String, String)] = [
        ("pm_gen_per_100km_since_regen", "PM_GEN ÷ distance since the last regeneration (0434) × 100, g/L per 100 km"),
        ("pm_gen_per_100km_recent", "PM_GEN growth over the last ~10 km of this cycle (recent_window_km), g/L per 100 km"),
        ("recent_window_km", "Distance the recent rates are over, km"),
        ("pm_gen_per_hour_recent", "PM_GEN growth over the last ~10 min of this drive, g/L per hour"),
        ("pm_acc_dsd_per_100km_recent", "PM_ACC_DSD (044B) change over the same stretch as pm_gen_per_100km_recent, g/L per 100 km"),
        ("km_to_trigger", "km until PM_GEN reaches 5.6 g/L at the recent pace (owner logs: a regeneration starts there with the oil warm)"),
        ("fuel_l_since_regen", "Fuel used since the last regeneration from PID 5E, only when all of it was recorded"),
        ("pm_gen_per_litre", "PM_GEN ÷ fuel_l_since_regen, g/L per litre (owner logs: ~6 g/L per ~17.7 L)"),
    ]

    private static let exportNotes: [String] = [
        """
        Mazda DIDs (04xx, 03xx, DAxx, DD01) and their scaling: FORScan Viewer 1.5.31's SKYACTIV-D PCM definitions \
        where it has them, community reverse engineering otherwise; not Mazda documents. The raw column has every \
        reply so other scalings can be applied (e.g. PM /628 instead of ·100/65536).
        """,
        """
        Since Nov 2026: regen_km is FORScan's scale for 0434, the whole value ·100/64000 km (older CSV files: \
        ·100/65536, 2.4 % less), and odometer_km is the true distance, the cluster's reading (odometer_shown_km) + \
        odometerOffsetKm, as this car's odometer was adjusted (in older files odometer_km is the cluster's \
        reading). The regeneration log (intervalKm, odometerStart / odometerEnd) was converted to both.
        """,
        """
        0380 byte A holds the regeneration REQUESTS (they drop while stopped): bit 0 forced (REG_REQ_F), bit 1 \
        automatic (REG_REQ_A), per FORScan's PCM definitions; Autobot only checked bit 0 before Nov 2026. The \
        count 0432 goes up as a regeneration ENDS on this car: in Autobot's regeneration log PM_ACC was already at \
        0–1 g/L every time it went up (280–286). PM_ACC_DSD is 044B; 042B is the fuel pump's suction control valve \
        current (FIP_SCV, A), which community lists had called PM_ACC_DSD: the 16–23 "after" values in older log \
        entries and the pm_acc_dsd column of CSV files from before Nov 2026 are that current read as g/L.
        """,
        """
        A sample in which the PCM answers nothing at all (ignition off, adapter busy) is a gap: no row is written and \
        nothing is held against the values. A value that has answered on a drive is never dropped on that drive; \
        one that hasn't answered 3 times in a row is asked every 2 min (drives[].notAnswered says which).
        """,
        """
        kind "check": the parked check started on the DPF screen (car standing, e.g. at a steady 3,000 rpm): the soot \
        model, air flow, boost, DPF pressure, EGR, intake shutter and temperatures read back to back for a few minutes.
        """,
        """
        PM_GEN is modelled from engine speed, intake air amount and injected fuel; PM combustion from the exhaust \
        gas temperature sensors; PM_ACC from the DPF differential pressure and exhaust gas amount (Mazda manual).
        """,
        "Standard PIDs (F4xx) are only asked when the PCM's supported-PID bitmap (drives[].support) lists them.",
        """
        engineHealth: the engine health watch (EngineHealth, AppConfig.EngineHealth): every item tied to fuel in the \
        oil with its level (unknown / normal / watch / high), value and normal range; its per-drive figures (warm-up, \
        oil heat, rail pressure gap, idle, air flow); the hot oil pressure baseline and recent readings at ~1,500 rpm \
        (0415, oil 85–95 °C); and the first injector learning values. oil_dilution_g (03E1) is every 30 s since \
        Nov 2026, in g (FORScan's scale).
        """,
        """
        The sweep reads 7E0 DIDs in recordSweepRanges a few per 30 s sample, raw only, to find where this PCM \
        keeps the exhaust temperatures (EXHTEMP1/2), the DPF differential pressure (EXHPRESS_DIF), the exhaust gas \
        amount (EXH_FL) and the injected fuel, whose DIDs aren't published. After the first pass it reads the ones \
        that answer, plus a couple of the ones not there per sample, in turn (one can be missed while the PCM is busy).
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
