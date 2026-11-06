// EngineHealth.swift
// The engine health watch: the values tied to fuel getting into the engine oil — and to what makes the
// DPF regenerate often, which is where most of that fuel comes from on the SKYACTIV-D 2.2 — each with
// its normal range and a "watch" level well before the PCM's own fault codes, so that a problem shows
// up here before a warning light does. It is fed by the DPF recorder's samples (DPFRecorder), so it
// works whenever live data runs, screen open or not, and is shown on the DPF screen.
//
//   Fuel in the oil   03E1 the PCM's own estimate of fuel in the oil (g), 0435 oil-deteriorated events,
//                     0415 oil pressure at a hot idle against its value after the oil change (fuel thins
//                     the oil; the PCM's own check, P253F, is a 40 kPa drop at 1,500 rpm), 0519 distance
//                     since the change
//   Temperatures      coolant warm-up (thermostat), oil hot enough to boil the fuel off again, the
//                     temperature sensors agreeing after a cold soak
//   Fuel system       rail pressure following the command, injector corrections and learning, idle speed
//   Regeneration      distance between regenerations, interrupted ones, PM_GEN growth
//   Air               boost against the PCM's target (F470; less air, more soot)
//
// A sample's reads span several seconds (sometimes much more), so the engine speed and road speed used
// with a value are the ones read nearest in time to it (the recorder passes them per DID).
//
// Ranges are in AppConfig.EngineHealth: Mazda's SKYACTIV-D 2.2 workshop manual where it gives a value,
// otherwise Autobot's own guide; each item says which. Levels: normal, watch (a little off: keep an eye
// on it), high (worth a check soon). Kept on the phone (not in test mode).

import Combine
import Foundation

private typealias Tuning = AppConfig.EngineHealth

final class EngineHealth: ObservableObject {

    enum Level: Int, Codable, Comparable {
        case unknown, normal, watch, high

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Item: Codable, Identifiable, Equatable {
        var id: String
        var group: String
        var title: String
        /// What it reads now: "3 g", "176 kPa (−9 since the oil change)".
        var value: String
        /// The normal range, and the PCM's own limit where there is one.
        var range: String
        var level: Level
        /// What it is and why it matters for fuel in the oil.
        var about: String
        /// What to check, while it isn't normal.
        var advice: String
    }

    /// One drive (live data from start to stop), as far as the watch is concerned.
    struct DriveStats: Codable, Equatable {
        var id: String
        var start: Date
        var last: Date
        var minutes = 0.0
        var movingMinutes = 0.0
        /// The first sample's temperatures and how long the engine had been off before it, hours.
        var firstCoolant: Double?
        var firstOil: Double?
        var firstIntake: Double?
        var firstAmbient: Double?
        var offHours: Double?
        var maxCoolant: Double?
        /// Minutes on the move until the coolant first reached Tuning.coolantWarm.
        var warmAfterMovingMinutes: Double?
        /// Samples on the move with the coolant under Tuning.coolantCruiseLow after it had warmed up.
        var coolantDips = 0
        var maxOil: Double?
        /// Minutes with the oil at Tuning.oilHot or more.
        var oilHotMinutes = 0.0
        /// Rail pressure: samples, and the sum of |actual − commanded|, MPa.
        var railSamples = 0
        var railGapSum = 0.0
        /// Warm idle: samples, and those more than Tuning.idleDeviationRPM from the target.
        var idleSamples = 0
        var idleOff = 0
        /// Warm, under high load: samples with boost and its target, and the sum of target − actual, kPa
        /// (optional: drives saved before them don't have them; boostSamples / boostGapSum, all loads, were
        /// dropped on 6 Nov 2026 — at part load the target isn't what the PCM chases).
        var highLoadBoostSamples: Int?
        var highLoadBoostGapSum: Double?
    }

    /// Everything kept between launches. New fields must be optional: a missing non-optional key would
    /// make the whole file unreadable.
    private struct State: Codable {
        /// The latest value of every column the watch uses (the slow and once-a-drive ones too), and when.
        var latest: [String: Double] = [:]
        var latestAt: [String: Date] = [:]
        /// 0519 distance since the oil change at the last reading, km (an oil change makes it go back).
        var oilChangeKm: Double?
        /// Oil pressure at a hot idle: the first Tuning.oilPressureSamples qualifying readings after the oil
        /// change (or since the watch started), and the latest ones, kPa.
        var pressureBaseline: [Double] = []
        var baselineAfterOilChange = false
        var pressureRecent: [Double] = []
        /// Which reading the baseline is of (a change of probe starts it again), and the latest hot readings
        /// at Tuning.oilPressureHighRPM, for the screen.
        var pressureProbe: String?
        var pressureHighRecent: [Double]?
        /// The last Tuning.injectorIdleReadings warm-idle readings of every injector correction, mm³/stroke
        /// (they read 0 while driving), and which readings they are (a change starts them again).
        var injectorIdle: [String: [Double]]?
        var injectorProbe: String?
        /// The first reading of every injector learning value (FI_LRN, µs), for the drift.
        var learningFirst: [String: Double] = [:]
        var learningFirstAt: Date?
        /// The last drives, oldest first; the last one is the current or latest drive.
        var drives: [DriveStats] = []
    }

    /// For the export.
    struct Export: Encodable {
        let items: [Item]
        let drives: [DriveStats]
        let oilChangeKm: Double?
        let oilPressureBaseline: [Double]
        let oilPressureBaselineAfterOilChange: Bool
        let oilPressureRecent: [Double]
        let oilPressureHighRPMRecent: [Double]
        let injectorCorrectionsAtIdle: [String: [Double]]
        let injectorLearningFirst: [String: Double]
        let latest: [String: Double]
    }

    @Published private(set) var items: [Item] = []

    var onLog: ((String) -> Void)?

    /// Items that aren't normal (watch or high).
    var concerns: [Item] { items.filter { $0.level >= .watch } }
    var worst: Level { items.map(\.level).max() ?? .unknown }

    var export: Export {
        Export(items: items, drives: state.drives, oilChangeKm: state.oilChangeKm,
               oilPressureBaseline: state.pressureBaseline,
               oilPressureBaselineAfterOilChange: state.baselineAfterOilChange,
               oilPressureRecent: state.pressureRecent, oilPressureHighRPMRecent: state.pressureHighRecent ?? [],
               injectorCorrectionsAtIdle: state.injectorIdle ?? [:], injectorLearningFirst: state.learningFirst,
               latest: state.latest)
    }

    private let persist: Bool
    private var state = State()
    private var regenEntries: [DPFRegenLog.Entry] = []
    private var pmGenPer100Km: Double?
    /// The previous sample's PM_GEN: falling means a regeneration is burning (also while its request bit is
    /// off, standing at the lights).
    private var lastPmGen: Double?

    private static let stateKey = "EngineHealth.state"

    /// The recorder's columns the watch keeps the latest value of.
    private static let kept: Set<String> = [
        "oil_dilution_g", "oil_dilution_events", "oil_change_km", "oil_pressure_kpa", "coolant_c", "oil_c",
        "intake_air_c", "ambient_c", "rail_cmd_kpa", "rail_act_kpa", "inj1_cmp_mm3", "inj2_cmp_mm3",
        "inj3_cmp_mm3", "inj4_cmp_mm3", "rpm_desired", "regen_req", "boost_target_kpa", "boost_kpa", "load_pct",
        "pm_gen", "pm_acc", "pm_acc_dsd",
    ]

    /// The oil pressure reading the baseline is of (see State.pressureProbe), and the injector readings kept
    /// (State.injectorProbe: since 7 Nov 2026 not while regenerating — they swing to ±1 mm³ then).
    private static let pressureProbe = "hot idle"
    private static let injectorProbe = "warm idle, not regenerating"

    init(persist: Bool, regenEntries: [DPFRegenLog.Entry]) {
        self.persist = persist
        self.regenEntries = regenEntries
        if persist, let data = UserDefaults.standard.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
        if state.pressureProbe != Self.pressureProbe {
            state.pressureProbe = Self.pressureProbe
            state.pressureBaseline = []
            state.pressureRecent = []
            state.baselineAfterOilChange = (state.oilChangeKm ?? .infinity) <= Tuning.oilPressureBaselineMaxKm
        }
        if state.injectorProbe != Self.injectorProbe {
            state.injectorProbe = Self.injectorProbe
            state.injectorIdle = nil
        }
        items = evaluate()
    }

    // MARK: Samples

    /// One recorder sample: its decoded values by CSV column, the RPM and road speed when it started, and
    /// the RPM / road speed read nearest in time to each DID's reply. `pmGenPer100Km`: PM_GEN growth since
    /// the last regeneration, once it means something.
    func observe(_ values: [String: Double], rpm: Double?, speed: Double?, rpmAt: [String: Double],
                 speedAt: [String: Double], at date: Date, drive: String, pmGenPer100Km: Double?,
                 regenEntries: [DPFRegenLog.Entry]) {
        self.regenEntries = regenEntries
        self.pmGenPer100Km = pmGenPer100Km
        for (column, value) in values where Self.kept.contains(column) || Self.isLearning(column) {
            state.latest[column] = value
            state.latestAt[column] = date
        }
        noteOilChange(values["oil_change_km"])
        for (column, value) in values where Self.isLearning(column) && state.learningFirst[column] == nil {
            state.learningFirst[column] = value
            if state.learningFirstAt == nil { state.learningFirstAt = date }
        }
        updateDrive(values, rpm: rpm, speed: speed, rpmAt: rpmAt, speedAt: speedAt, at: date, drive: drive)
        if let pressure = values["oil_pressure_kpa"], let engine = rpmAt["0415"],
           let oil = values["oil_c"], Tuning.oilPressureOilTemp.contains(oil) {
            if Tuning.oilPressureRPM.contains(engine), (speedAt["0415"] ?? speed ?? 99) < Tuning.standingSpeed {
                if state.pressureBaseline.count < Tuning.oilPressureSamples { state.pressureBaseline.append(pressure) }
                state.pressureRecent.append(pressure)
                if state.pressureRecent.count > Tuning.oilPressureSamples { state.pressureRecent.removeFirst() }
            } else if Tuning.oilPressureHighRPM.contains(engine) {
                var high = state.pressureHighRecent ?? []
                high.append(pressure)
                if high.count > Tuning.oilPressureSamples { high.removeFirst(high.count - Tuning.oilPressureSamples) }
                state.pressureHighRecent = high
            }
        }
        let burning = (values["regen_req"] ?? 0) != 0
            || (values["pm_gen"].flatMap { now in lastPmGen.map { now < $0 } } ?? false)
        if let pmGen = values["pm_gen"] { lastPmGen = pmGen }
        if !burning { noteInjectorCorrections(values, rpmAt: rpmAt, speedAt: speedAt, speed: speed) }
        publish()
        save()
    }

    /// The regeneration log changed (or the screen opened): its items again.
    func refresh(regenEntries: [DPFRegenLog.Entry]) {
        self.regenEntries = regenEntries
        publish()
    }

    private static func isLearning(_ column: String) -> Bool {
        column.hasPrefix("inj") && column.contains("_lrn") && column.hasSuffix("_us")
    }

    /// INJx_CMP only means something around idle (it reads 0 while driving; at idle, in gear or not, it
    /// doesn't): warm readings below Tuning.idleMaxRPM are kept, not the all-zero ones.
    private func noteInjectorCorrections(_ values: [String: Double], rpmAt: [String: Double],
                                         speedAt: [String: Double], speed: Double?) {
        let warm = (values["coolant_c"] ?? state.latest["coolant_c"] ?? 0) >= Tuning.coolantWarm
        let columns = (1...4).map { "inj\($0)_cmp_mm3" }
        guard warm, columns.contains(where: { (values[$0] ?? 0) != 0 }) else { return }
        var kept = state.injectorIdle ?? [:]
        for (index, did) in ["098A", "098B", "098C", "098D"].enumerated() {
            let column = columns[index]
            guard let value = values[column], let engine = rpmAt[did], engine < Tuning.idleMaxRPM else { continue }
            var readings = kept[column] ?? []
            readings.append(value)
            if readings.count > Tuning.injectorIdleReadings {
                readings.removeFirst(readings.count - Tuning.injectorIdleReadings)
            }
            kept[column] = readings
        }
        state.injectorIdle = kept
    }

    /// 0519 going back means the oil was changed: the oil pressure baseline starts again.
    private func noteOilChange(_ km: Double?) {
        guard let km else { return }
        if let old = state.oilChangeKm, km < old - Tuning.oilChangeSeenDropKm {
            state.pressureBaseline = []
            state.pressureRecent = []
            state.baselineAfterOilChange = true
            onLog?(String(format: "Engine health: oil change seen (0519 %.0f → %.0f km), the oil pressure "
                          + "baseline starts again", old, km))
        } else if state.oilChangeKm == nil, state.pressureBaseline.isEmpty, km <= Tuning.oilPressureBaselineMaxKm {
            state.baselineAfterOilChange = true
        }
        state.oilChangeKm = km
    }

    private func updateDrive(_ values: [String: Double], rpm: Double?, speed: Double?, rpmAt: [String: Double],
                             speedAt: [String: Double], at date: Date, drive: String) {
        var stats: DriveStats
        if let last = state.drives.last, last.id == drive {
            stats = last
            state.drives.removeLast()
        } else {
            stats = DriveStats(id: drive, start: date, last: date)
            stats.offHours = state.drives.last.map { date.timeIntervalSince($0.last) / 3600 }
        }
        let minutes = min(max(date.timeIntervalSince(stats.last), 0), Tuning.maxSampleGap) / 60
        stats.last = date
        let moving = (speed ?? 0) >= Tuning.movingSpeed
        stats.minutes += minutes
        if moving { stats.movingMinutes += minutes }
        if stats.minutes <= Tuning.firstSampleMinutes {
            if stats.firstCoolant == nil { stats.firstCoolant = values["coolant_c"] }
            if stats.firstOil == nil { stats.firstOil = values["oil_c"] }
            if stats.firstIntake == nil { stats.firstIntake = values["intake_air_c"] }
            if stats.firstAmbient == nil { stats.firstAmbient = values["ambient_c"] }
        }
        let coolant = values["coolant_c"]
        if let coolant {
            stats.maxCoolant = max(stats.maxCoolant ?? coolant, coolant)
            if stats.warmAfterMovingMinutes == nil, coolant >= Tuning.coolantWarm {
                stats.warmAfterMovingMinutes = stats.movingMinutes
            } else if stats.warmAfterMovingMinutes != nil, moving, coolant < Tuning.coolantCruiseLow {
                stats.coolantDips += 1
            }
        }
        if let oil = values["oil_c"] {
            stats.maxOil = max(stats.maxOil ?? oil, oil)
            if oil >= Tuning.oilHot { stats.oilHotMinutes += minutes }
        }
        let warm = (coolant ?? state.latest["coolant_c"] ?? 0) >= Tuning.coolantWarm
        if let command = values["rail_cmd_kpa"], let actual = values["rail_act_kpa"], (rpm ?? 0) >= 700 {
            stats.railSamples += 1
            stats.railGapSum += abs(actual - command) / 1000
        }
        if let engine = rpmAt["0308"] ?? rpm, let target = values["rpm_desired"], target > 0, warm,
           (speedAt["0308"] ?? speed ?? 99) < Tuning.standingSpeed, engine < Tuning.idleMaxRPM {
            stats.idleSamples += 1
            if abs(engine - target) > Tuning.idleDeviationRPM { stats.idleOff += 1 }
        }
        if let target = values["boost_target_kpa"], let actual = values["boost_kpa"], let engine = rpmAt["F470"],
           Tuning.boostRPM.contains(engine), (values["load_pct"] ?? 0) >= Tuning.boostMinLoad, warm,
           (speedAt["F470"] ?? speed ?? 0) >= Tuning.movingSpeed {
            stats.highLoadBoostSamples = (stats.highLoadBoostSamples ?? 0) + 1
            stats.highLoadBoostGapSum = (stats.highLoadBoostGapSum ?? 0) + (target - actual)
        }
        state.drives.append(stats)
        if state.drives.count > Tuning.drivesKept { state.drives.removeFirst(state.drives.count - Tuning.drivesKept) }
    }

    private func publish() {
        let new = evaluate()
        let old = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.level) })
        for item in new where item.level >= .watch && item.level > (old[item.id] ?? .unknown) {
            onLog?("Engine health: \(item.title) — \(item.level == .high ? "check soon" : "watch"): \(item.value)")
        }
        if new != items { items = new }
    }

    private func save() {
        guard persist, let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.stateKey)
    }

    // MARK: The items

    private func evaluate() -> [Item] {
        [oilDilution(), oilEvents(), oilPressure(), oilChange(),
         warmUp(), oilHeat(), coldStart(),
         rail(), injectorCorrections(), injectorLearning(), idle(),
         regenInterval(), regenInterrupted(), pmGenRate(), sootAfterRegen(), pressureVsModel(),
         boost()]
    }

    private static let oilGroup = "Fuel in the oil"
    private static let temperatureGroup = "Engine temperature"
    private static let fuelGroup = "Fuel system (fuel reaching the oil without a regeneration)"
    private static let regenGroup = "Regeneration (the main source of fuel in the oil)"
    private static let airGroup = "Air (less air, more soot, more regenerations)"

    private func oilDilution() -> Item {
        let grams = state.latest["oil_dilution_g"]
        var value = grams.map { String(format: "%.0f g", $0) } ?? "--"
        let rises = regenEntries.prefix(Tuning.regenEntriesUsed).compactMap { entry -> Double? in
            guard let before = entry.oilDilutionBefore, let after = entry.oilDilutionAfter else { return nil }
            return after - before
        }
        if !rises.isEmpty {
            value += String(format: " · %+.0f g a regeneration", rises.reduce(0, +) / Double(rises.count))
        }
        return Item(id: "oil_dilution", group: Self.oilGroup, title: "Fuel in the oil, PCM's estimate (03E1)",
                    value: value,
                    range: String(format: "normal under %.0f g · PCM: %.0f g sets P252F (no light), %.0f g P253F",
                                  Tuning.oilDilutionWatch, Tuning.oilDilutionP252F, Tuning.oilDilutionP253F),
                    level: Self.level(grams, watch: Tuning.oilDilutionWatch, high: Tuning.oilDilutionHigh),
                    about: "OIL_DIL: the PCM adds up the fuel each regeneration washes into the oil and takes "
                    + "off what boils away on long drives; it resets with the engine oil data reset after an oil "
                    + "change. Unit as FORScan shows it (g). It only counts regenerations: fuel from a leaking "
                    + "injector isn't in it, so a dipstick at X with a low value here points elsewhere.",
                    advice: "Check the dipstick: change the oil and filter before it reaches X, then do the engine "
                    + "oil data reset (Mazda). Longer drives let the fuel boil off.")
    }

    private func oilEvents() -> Item {
        let events = state.latest["oil_dilution_events"]
        return Item(id: "oil_events", group: Self.oilGroup, title: "Oil judged deteriorated (0435)",
                    value: events.map { String(format: "%.0f times", $0) } ?? "--",
                    range: "normal 0 · each one is the PCM deciding the oil is deteriorated (P253F)",
                    level: Self.level(events, watch: 1, high: 2),
                    about: "OIL_DIL_CNT: how many times the PCM found the oil deteriorated, from its fuel-in-oil "
                    + "estimate or from the oil pressure having dropped since the oil change.",
                    advice: "Change the oil and do the engine oil data reset; if it comes back soon, look at the "
                    + "oil pressure item and the oil pressure / temperature sensor.")
    }

    private func oilPressure() -> Item {
        let recent = Self.median(state.pressureRecent)
        let baseline = state.pressureBaseline.count >= Tuning.oilPressureMinSamples
            ? Self.median(state.pressureBaseline) : nil
        var value = "--"
        var level = Level.unknown
        if let recent, state.pressureRecent.count >= Tuning.oilPressureMinSamples {
            value = String(format: "%.0f kPa", recent)
            level = recent < Tuning.oilPressureLow ? .watch : .normal
            if let baseline {
                let drop = baseline - recent
                value += " (" + (state.baselineAfterOilChange ? "after the oil change" : "first readings")
                    + String(format: " %.0f, %+.0f)", baseline, recent - baseline)
                if drop >= Tuning.oilPressureDropHigh { level = .high }
                else if drop >= Tuning.oilPressureDropWatch { level = max(level, .watch) }
            } else {
                value += String(format: " (baseline %d/%d readings)", state.pressureBaseline.count,
                                Tuning.oilPressureMinSamples)
            }
        } else if !state.pressureRecent.isEmpty {
            value = String(format: "%d/%d readings", state.pressureRecent.count, Tuning.oilPressureMinSamples)
        }
        if let high = Self.median(state.pressureHighRecent ?? []) {
            value += String(format: " · %.0f–%.0f rpm %.0f kPa", Tuning.oilPressureHighRPM.lowerBound,
                            Tuning.oilPressureHighRPM.upperBound, high)
        }
        return Item(id: "oil_pressure", group: Self.oilGroup, title: "Oil pressure at a hot idle (0415)",
                    value: value,
                    range: String(format: "Mazda: about 184 kPa at a warm idle, 366 kPa at 4,000 rpm · watch at "
                                  + "−%.0f kPa from after the oil change, or under %.0f kPa · PCM: −%.0f kPa at "
                                  + "1,500 rpm sets P253F", Tuning.oilPressureDropWatch, Tuning.oilPressureLow,
                                  Tuning.oilPressureDropP253F),
                    level: level,
                    about: String(format: "EOP with the oil at %.0f–%.0f °C, standing at %.0f–%.0f rpm (the RPM read "
                                  + "next to it), the median of the last %d such readings. Fuel thins the oil, so its "
                                  + "pressure falls as fuel builds up; the PCM compares it with the value after the "
                                  + "oil change (P253F). At a hot idle the pressure is steady and comes up at every "
                                  + "stop. 0415 in kPa is FORScan's definition from other Mazda PCMs; it matches "
                                  + "Mazda's reference values on this car.",
                                  Tuning.oilPressureOilTemp.lowerBound, Tuning.oilPressureOilTemp.upperBound,
                                  Tuning.oilPressureRPM.lowerBound, Tuning.oilPressureRPM.upperBound,
                                  Tuning.oilPressureSamples),
                    advice: "Thinner oil: check the dipstick and smell the oil for diesel; an oil analysis gives the "
                    + "fuel %. A sudden change can also be the oil pressure sensor.")
    }

    private func oilChange() -> Item {
        let km = state.latest["oil_change_km"]
        return Item(id: "oil_change", group: Self.oilGroup, title: "Since the oil change (0519)",
                    value: km.map { String(format: "%.0f km", $0) } ?? "--",
                    range: String(format: "guide with frequent regenerations: change by %.0f–%.0f km, or when the "
                                  + "dipstick reaches X", Tuning.oilChangeWatchKm, Tuning.oilChangeHighKm),
                    level: Self.level(km, watch: Tuning.oilChangeWatchKm, high: Tuning.oilChangeHighKm),
                    about: "OILCHG_DIS: the PCM's distance since the engine oil data reset (4 km steps). Diluted oil "
                    + "wears the timing chain, turbo and rings sooner, so a shorter interval is cheap insurance.",
                    advice: "Plan an oil and filter change (low-ash oil to Mazda's spec) and the engine oil data reset.")
    }

    private func warmUp() -> Item {
        let drives = state.drives.filter { $0.movingMinutes >= Tuning.coolantWarmUpMinutes
            && ($0.firstAmbient ?? 10) >= Tuning.coolantMinAmbient }
        let latest = state.drives.last
        var value = "--"
        if let latest, let max = latest.maxCoolant {
            value = String(format: "max %.0f °C", max)
            if let warm = latest.warmAfterMovingMinutes {
                value = String(format: "%.0f °C after %.0f min · ", Tuning.coolantWarm, warm) + value
            }
            if latest.coolantDips > 0 { value += " · \(latest.coolantDips) dips" }
        }
        var level = Level.unknown
        if !drives.isEmpty {
            let slow = drives.suffix(3).filter { ($0.warmAfterMovingMinutes ?? .infinity) > Tuning.coolantWarmUpMinutes }
            let dips = drives.suffix(3).filter { $0.coolantDips >= Tuning.coolantDipsWatch }
            level = slow.count >= 2 ? .high : (slow.isEmpty && dips.isEmpty ? .normal : .watch)
        }
        if (state.drives.compactMap(\.maxCoolant).max() ?? 0) >= Tuning.coolantHigh { level = .high }
        return Item(id: "warm_up", group: Self.temperatureGroup, title: "Coolant warm-up and thermostat (F405)",
                    value: value,
                    range: String(format: "Mazda: thermostat opens 80–84 °C, fully 95 °C · watch: under %.0f °C after "
                                  + "%.0f min of driving, or under %.0f °C on the move once warm", Tuning.coolantWarm,
                                  Tuning.coolantWarmUpMinutes, Tuning.coolantCruiseLow),
                    level: level,
                    about: "A thermostat stuck open keeps the engine cold: the PCM injects more fuel, regenerations "
                    + "fail (REG_FAIL ECT_LOW) or run longer, and fuel in the oil can't boil off. Drives starting "
                    + "below freezing aren't counted.",
                    advice: "Check the thermostat (and that the coolant level is right); a slow warm-up on every drive "
                    + "is the typical sign of one stuck open.")
    }

    private func oilHeat() -> Item {
        let finished = state.drives.dropLast()
        var streak = 0
        for drive in finished.reversed() {
            guard (drive.maxOil ?? 0) < Tuning.oilWarm else { break }
            streak += 1
        }
        let hotDrives = state.drives.suffix(Tuning.drivesKept).filter { $0.oilHotMinutes >= Tuning.oilHotMinutes }.count
        var value = "--"
        if let latest = state.drives.last, let max = latest.maxOil {
            value = String(format: "this drive max %.0f °C, %.0f min ≥ %.0f °C · %d of the last %d drives got it hot",
                           max, latest.oilHotMinutes, Tuning.oilHot, hotDrives, state.drives.count)
        }
        let level: Level = state.drives.isEmpty ? .unknown
            : streak >= Tuning.coldDrivesHigh ? .high : streak >= Tuning.coldDrivesWatch ? .watch : .normal
        return Item(id: "oil_heat", group: Self.temperatureGroup, title: "Oil hot enough to boil the fuel off (F45C)",
                    value: value,
                    range: String(format: "guide: fuel boils off above ~%.0f °C oil · watch: %d drives in a row whose "
                                  + "oil never reached %.0f °C", Tuning.oilHot, Tuning.coldDrivesWatch, Tuning.oilWarm),
                    level: level,
                    about: "Diesel in the oil only evaporates when the oil stays hot for a while. Short drives "
                    + "(the oil takes 20–30 min to reach 90 °C) let the fuel from every regeneration build up.",
                    advice: "Add a 20–30 min drive at a steady speed now and then, ideally right after a "
                    + "regeneration, so the fuel boils off.")
    }

    private func coldStart() -> Item {
        // A cold start: long enough since the last recorded drive, and the coolant still cold (the car may
        // have been driven without Autobot in between).
        guard let drive = state.drives.last(where: { ($0.offHours ?? 0) >= Tuning.coldStartOffHours
            && ($0.firstCoolant ?? 0) <= Tuning.coldStartMaxCoolant }) else {
            return Item(id: "cold_start", group: Self.temperatureGroup,
                        title: "Temperature sensors after a cold soak", value: "--",
                        range: coldStartRange, level: .unknown, about: coldStartAbout, advice: coldStartAdvice)
        }
        let named: [(String, Double?)] = [("coolant", drive.firstCoolant), ("oil", drive.firstOil),
                                          ("intake", drive.firstIntake), ("outside", drive.firstAmbient)]
        let readings: [(String, Double)] = named.compactMap { pair in pair.1.map { (pair.0, $0) } }
        var value = readings.map { $0.0 + " " + String(format: "%.0f", $0.1) }.joined(separator: ", ")
        if !readings.isEmpty { value += " °C" }
        if let hours = drive.offHours { value += String(format: " after %.0f h off", hours) }
        // The two engine sensors should agree, and so should the two air sensors. The engine may still be
        // warmer than the air after a night (a big block keeps its heat), but never colder: a coolant or oil
        // reading below the air is a sensor reading low, the harmful way round.
        var level = Level.unknown
        var gaps: [Double] = []
        if let coolant = drive.firstCoolant, let oil = drive.firstOil { gaps.append(abs(coolant - oil)) }
        if let intake = drive.firstIntake, let outside = drive.firstAmbient { gaps.append(abs(intake - outside)) }
        let air = [drive.firstIntake, drive.firstAmbient].compactMap { $0 }.min()
        let engine = [drive.firstCoolant, drive.firstOil].compactMap { $0 }.min()
        if let air, let engine { gaps.append(max(0, air - engine)) }
        if let worst = gaps.max() {
            level = Self.level(worst, watch: Tuning.coldStartSpreadWatch, high: Tuning.coldStartSpreadHigh)
        }
        return Item(id: "cold_start", group: Self.temperatureGroup, title: "Temperature sensors after a cold soak",
                    value: value, range: coldStartRange, level: level, about: coldStartAbout, advice: coldStartAdvice)
    }

    private var coldStartRange: String {
        String(format: "guide: after %.0f h off, coolant and oil within %.0f °C of each other, intake and outside "
               + "too, and the engine not colder than the air", Tuning.coldStartOffHours, Tuning.coldStartSpreadWatch)
    }
    private let coldStartAbout = "Coolant, oil, intake air and outside air at the first sample after the car stood "
        + "for hours. The engine can still be warmer than the air after a night; a coolant sensor reading low, "
        + "though, makes the PCM treat the engine as cold: more fuel, longer glow and post injection, failed "
        + "regenerations."
    private let coldStartAdvice = "Compare again on the next cold start; if one sensor keeps reading apart from "
        + "the others, test that sensor (Mazda's ECT sensor inspection)."

    private func rail() -> Item {
        let drive = Self.latestDrive(state.drives) { $0.railSamples >= Tuning.railMinSamples }
        let gap = drive.map { $0.railGapSum / Double($0.railSamples) }
        return Item(id: "rail", group: Self.fuelGroup, title: "Rail pressure follows the command (F46D)",
                    value: drive.map { String(format: "%.1f MPa average gap over %d samples", $0.railGapSum
                                              / Double($0.railSamples), $0.railSamples) } ?? "--",
                    range: String(format: "Mazda: about 40 MPa at idle, 80 MPa at 4,000 rpm · guide: average "
                                  + "|actual − commanded| up to %.0f MPa", Tuning.railGapWatch),
                    level: Self.level(gap, watch: Tuning.railGapWatch, high: Tuning.railGapHigh),
                    about: "The common rail's actual pressure against what the PCM asks for, over the drive. A pump, "
                    + "suction control valve or a leaking injector makes it lag.",
                    advice: "Read the fuel injector corrections next; a leak-off (return flow) test of the injectors "
                    + "shows a leaking one.")
    }

    private func injectorCorrections() -> Item {
        let kept = state.injectorIdle ?? [:]
        let values = (1...4).map { Self.median(kept["inj\($0)_cmp_mm3"] ?? []) }
        let known = values.compactMap { $0 }
        let count = kept.values.map(\.count).min() ?? 0
        var value = "--"
        if !known.isEmpty {
            value = values.map { $0.map { String(format: "%+.2f", $0) } ?? "--" }.joined(separator: " / ")
                + " mm³ (median of \(count) warm idles)"
        }
        return Item(id: "injector_correction", group: Self.fuelGroup, title: "Injector corrections at a warm idle (098A–098D)",
                    value: value,
                    range: String(format: "Mazda reference about ±0.3 mm³/stroke · guide: watch at ±%.1f, high at ±%.1f",
                                  Tuning.injectorCorrectionWatch, Tuning.injectorCorrectionHigh),
                    level: Self.level(known.map(abs).max(), watch: Tuning.injectorCorrectionWatch,
                                      high: Tuning.injectorCorrectionHigh),
                    about: "INJx_CMP, injectors 1–4: how much the PCM trims each injector's quantity to even out the "
                    + "idle (it reads 0 while driving, and swings to ±1 mm³ during a regeneration, so only warm "
                    + "idles without one count). Negative = the injector "
                    + "gives more than it should. One drifting away from the others is a worn or dripping injector "
                    + "— a dripping one puts fuel in the oil without any regeneration, and makes soot.",
                    advice: "Have the injectors checked (leak-off test, balance); compare with the injector "
                    + "learning drift below.")
    }

    private func injectorLearning() -> Item {
        var drift: Double?
        var column = ""
        for (key, first) in state.learningFirst {
            guard let now = state.latest[key] else { continue }
            if abs(now - first) > (drift ?? -1) { drift = abs(now - first); column = key }
        }
        var value = "--"
        if let drift {
            value = String(format: "largest change %.0f µs", drift)
            if !column.isEmpty, drift > 0 { value += " (" + column.replacingOccurrences(of: "_us", with: "") + ")" }
            if let since = state.learningFirstAt {
                value += " since " + since.formatted(date: .abbreviated, time: .omitted)
            }
        }
        return Item(id: "injector_learning", group: Self.fuelGroup, title: "Injector learning drift (0436–0439)",
                    value: value,
                    range: String(format: "guide: watch at a %.0f µs change since the first reading, high at %.0f µs",
                                  Tuning.injectorLearningDriftWatch, Tuning.injectorLearningDriftHigh),
                    level: Self.level(drift, watch: Tuning.injectorLearningDriftWatch,
                                      high: Tuning.injectorLearningDriftHigh),
                    about: "FI_LRN: each injector's learned timing correction at 35, 65, 100 and 140 MPa, read once a "
                    + "drive. An injector wearing shows as its values creeping away from where they started.",
                    advice: "Note which injector moves; Mazda's injector amount correction (learning) and a "
                    + "leak-off test tell whether it needs replacing.")
    }

    private func idle() -> Item {
        let drive = Self.latestDrive(state.drives) { $0.idleSamples >= Tuning.idleMinSamples }
        let share = drive.map { Double($0.idleOff) / Double($0.idleSamples) }
        return Item(id: "idle", group: Self.fuelGroup, title: "Warm idle speed vs target (0308)",
                    value: drive.map { String(format: "%.0f %% of %d samples off by more than %.0f rpm",
                                              Double($0.idleOff) * 100 / Double($0.idleSamples), $0.idleSamples,
                                              Tuning.idleDeviationRPM) } ?? "--",
                    range: String(format: "Mazda: 800 rpm (automatic), within %.0f rpm of the target · guide: watch "
                                  + "when %.0f %% of warm-idle samples are off", Tuning.idleDeviationRPM,
                                  Tuning.idleOffShareWatch * 100),
                    level: Self.level(share, watch: Tuning.idleOffShareWatch, high: Tuning.idleOffShareHigh),
                    about: "An injector delivering too much or too little, a glow plug or an air leak shows first as "
                    + "an idle the PCM can't hold.",
                    advice: "Look at the injector corrections; an idle that hunts or shakes is worth a dealer check.")
    }

    private func regenInterval() -> Item {
        let intervals = regenEntries.filter { $0.outcome != .interrupted && !$0.approximate }
            .compactMap(\.intervalKm).prefix(Tuning.regenIntervalsAveraged)
        let average = intervals.isEmpty ? nil : intervals.reduce(0, +) / Double(intervals.count)
        var level = Level.unknown
        if let average {
            level = average < Tuning.regenIntervalHighKm ? .high : average < Tuning.regenIntervalNormalKm ? .watch : .normal
        }
        return Item(id: "regen_interval", group: Self.regenGroup, title: "Distance between regenerations",
                    value: average.map { String(format: "%.0f km on average over the last %d", $0, intervals.count) } ?? "--",
                    range: String(format: "owners: 250–400 km in mixed driving · guide: watch under %.0f km, high "
                                  + "under %.0f km", Tuning.regenIntervalNormalKm, Tuning.regenIntervalHighKm),
                    level: level,
                    about: "Every regeneration injects extra fuel late in the stroke (post injection) to heat the "
                    + "DPF; some of it gets past the rings into the oil. Frequent regenerations are the main source "
                    + "of fuel in the oil on this engine.",
                    advice: "See the items below: the soot model's growth (PM_GEN), the pressure-based estimate "
                    + "against it, and the soot left after a regeneration (ash) — which of them brings the "
                    + "regenerations forward.")
    }

    private func regenInterrupted() -> Item {
        let recent = regenEntries.prefix(Tuning.regenEntriesUsed)
        let interrupted = recent.filter { $0.outcome == .interrupted }.count
        return Item(id: "regen_interrupted", group: Self.regenGroup, title: "Interrupted regenerations",
                    value: recent.isEmpty ? "--" : "\(interrupted) of the last \(recent.count)",
                    range: String(format: "guide: watch at %d of the last %d, high at %d", Tuning.interruptedWatch,
                                  Tuning.regenEntriesUsed, Tuning.interruptedHigh),
                    level: recent.isEmpty ? .unknown : Self.level(Double(interrupted),
                                                                  watch: Double(Tuning.interruptedWatch),
                                                                  high: Double(Tuning.interruptedHigh)),
                    about: "A regeneration stopped part-way (engine off, slow traffic) has already put its fuel in "
                    + "the oil and has to start again next drive.",
                    advice: "When the DPF monitor says a regeneration is running, keep driving until it ends "
                    + "(10–20 min at 15 km/h or more).")
    }

    private func pmGenRate() -> Item {
        let rate = pmGenPer100Km
        return Item(id: "pm_gen_rate", group: Self.regenGroup, title: "Soot growth (PM_GEN per 100 km)",
                    value: rate.map { String(format: "%.1f g/L per 100 km since the last regeneration", $0) } ?? "--",
                    range: String(format: "guide: up to %.1f (5.6 g/L in %.0f km or more) · high above %.1f",
                                  Tuning.pmGenRateWatch, 560 / Tuning.pmGenRateWatch, Tuning.pmGenRateHigh),
                    level: Self.level(rate, watch: Tuning.pmGenRateWatch, high: Tuning.pmGenRateHigh),
                    about: "How fast the PCM's soot model fills up: it decides when the next regeneration comes.",
                    advice: "Fast growth comes from short / cold driving, EGR and air flow, injectors, or the PCM "
                    + "calibration: see the other items and the DPF recorder's export.")
    }

    private func boost() -> Item {
        let drive = Self.latestDrive(state.drives) { ($0.highLoadBoostSamples ?? 0) >= Tuning.boostMinSamples }
        let gap = drive.map { ($0.highLoadBoostGapSum ?? 0) / Double($0.highLoadBoostSamples ?? 1) }
        var level = Self.level(gap, watch: Tuning.boostGapWatch, high: .infinity)
        if level == .high { level = .watch }
        return Item(id: "boost", group: Self.airGroup, title: "Boost vs the PCM's target at high load (F470)",
                    value: drive.map { String(format: "%.0f kPa under the target on average over %d samples",
                                              ($0.highLoadBoostGapSum ?? 0) / Double($0.highLoadBoostSamples ?? 1),
                                              $0.highLoadBoostSamples ?? 0) } ?? "--",
                    range: String(format: "guide: warm, %.0f–%.0f rpm, load %.0f %% or more: within %.0f kPa of the "
                                  + "target on average (Mazda gives no figure)", Tuning.boostRPM.lowerBound,
                                  Tuning.boostRPM.upperBound, Tuning.boostMinLoad, Tuning.boostGapWatch),
                    level: level,
                    about: "PID 70: the boost the PCM asks for against the MAP sensor's. Only high load counts: at "
                    + "part load the PCM lets boost fall short of this target (EGR comes first; on this car it "
                    + "read 30 kPa short at a steady 100 km/h and asked for 228 kPa with no fuel at all), while "
                    + "under high load it reaches it. A boost leak or a sticking turbo valve shows there.",
                    advice: "Worth a boost-leak (smoke) test of the intercooler pipes and hoses, and a check of the "
                    + "turbo's regulating valve, wastegate and their vacuum lines.")
    }

    /// The DPF's soot right after a regeneration: about 0 when the filter is clean (Mazda's P243C check);
    /// what stays is ash or a clogged filter, and it brings the next regeneration forward.
    private func sootAfterRegen() -> Item {
        let completed = regenEntries.filter { $0.outcome != .interrupted }
        let readings: [Double] = completed.prefix(3).compactMap { entry -> Double? in
            if let desired = entry.sootDesiredAfter, desired <= Tuning.sootAfterPlausibleMax { return desired }
            return entry.sootAfter
        }
        return Item(id: "soot_after_regen", group: Self.regenGroup, title: "Soot left right after a regeneration",
                    value: readings.isEmpty ? "--" : readings.map { String(format: "%.2f", $0) }
                        .joined(separator: " / ") + " g/L (latest first)",
                    range: String(format: "Mazda: approx. 0 after a complete regeneration (P243C) · FORScan forum: "
                                  + "~0.1 typical · guide: watch from %.1f, high from %.1f g/L",
                                  Tuning.sootAfterWatch, Tuning.sootAfterHigh),
                    level: Self.level(readings.first, watch: Tuning.sootAfterWatch, high: Tuning.sootAfterHigh),
                    about: "PM_ACC_DSD (044B; PM_ACC in older log entries) when the count goes up. Soot burns in a "
                    + "regeneration, ash doesn't: what stays makes the pressure-based estimate start the next cycle "
                    + "higher, so regenerations come sooner. Mazda's P243C steps: a forced regeneration, and if "
                    + "PM_ACC_DSD isn't about 0 afterwards, the DPF is clogged.",
                    advice: "Have a forced regeneration done (FORScan / dealer) and read PM_ACC_DSD after it; if it "
                    + "stays up, the DPF needs cleaning or replacing (ash after many km), or check the DPF pressure "
                    + "sensor and its hoses.")
    }

    /// The pressure-based soot estimate against the model's. Regeneration starts when the PCM's soot
    /// estimate (it uses both) is high enough; a pressure-based one well above the model's brings it forward.
    private func pressureVsModel() -> Item {
        let generated = state.latest["pm_gen"]
        let accumulated = state.latest["pm_acc_dsd"] ?? state.latest["pm_acc"]
        var ratio: Double?
        if let generated, let accumulated, generated >= Tuning.pressureVsModelMinGen { ratio = accumulated / generated }
        var value = "--"
        if let generated, let accumulated {
            value = String(format: "PM_ACC_DSD %.2f / PM_GEN %.2f g/L", accumulated, generated)
            if let ratio { value += String(format: " = %.2f", ratio) }
        }
        return Item(id: "pressure_vs_model", group: Self.regenGroup, title: "Pressure-based soot vs the model",
                    value: value,
                    range: String(format: "guide: up to %.1f× · Mazda: 2× or more at 3,000 rpm → check the DPF "
                                  + "pressure sensor (P243C)", Tuning.pressureVsModelWatch),
                    level: Self.level(ratio, watch: Tuning.pressureVsModelWatch, high: Tuning.pressureVsModelHigh),
                    about: "PM_ACC_DSD (044B) behaves like the estimate from the DPF's differential pressure: it "
                    + "rises with exhaust flow on the motorway and stays up after a burn (7 Nov 2026: ~0.9 g/L while "
                    + "PM_ACC fell to 0.2). PM_GEN is the engine model (fuel, air, RPM); PM_ACC (042C) the PCM's "
                    + "running estimate, which falls smoothly during a burn. The PCM uses both kinds; when the "
                    + "pressure-based one runs ahead, the regeneration comes sooner than the model alone would start "
                    + "it. Judged from PM_GEN ≥ 1 g/L.",
                    advice: "Watch which one is highest when the next regeneration starts (the recorder notes it); "
                    + "if it's the pressure-based one, ash in the DPF, the pressure sensor or its hoses are the "
                    + "suspects.")
    }

    // MARK: Helpers

    /// normal below `watch`, watch below `high`, high from there; unknown without a value.
    private static func level(_ value: Double?, watch: Double, high: Double) -> Level {
        guard let value else { return .unknown }
        return value >= high ? .high : value >= watch ? .watch : .normal
    }

    /// The current drive if it qualifies, else the latest one that does.
    private static func latestDrive(_ drives: [DriveStats], where qualifies: (DriveStats) -> Bool) -> DriveStats? {
        drives.last(where: qualifies)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
