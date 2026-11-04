// EngineHealth.swift
// The engine health watch: the values tied to fuel getting into the engine oil — and to what makes the
// DPF regenerate often, which is where most of that fuel comes from on the SKYACTIV-D 2.2 — each with
// its normal range and a "watch" level well before the PCM's own fault codes, so that a problem shows
// up here before a warning light does. It is fed by the DPF recorder's samples (DPFRecorder), so it
// works whenever live data runs, screen open or not, and is shown on the DPF screen.
//
//   Fuel in the oil   03E1 the PCM's own estimate of fuel in the oil (g), 0435 oil-deteriorated events,
//                     0415 hot oil pressure at ~1,500 rpm against its value after the oil change (fuel
//                     thins the oil; the PCM sets P253F at a 40 kPa drop), 0519 distance since the change
//   Temperatures      coolant warm-up (thermostat), oil hot enough to boil the fuel off again, the
//                     temperature sensors agreeing after a cold soak
//   Fuel system       rail pressure following the command, injector corrections and learning, idle speed
//   Regeneration      distance between regenerations, interrupted ones, PM_GEN growth
//   Air               air flow (F466) against the PCM's target (EGR, MAF sensor, boost leaks: more soot)
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
        /// Warm steady driving: samples with air flow and its target, and those off by more than
        /// Tuning.mafDeviation.
        var mafSamples = 0
        var mafOff = 0
    }

    /// Everything kept between launches. New fields must be optional: a missing non-optional key would
    /// make the whole file unreadable.
    private struct State: Codable {
        /// The latest value of every column the watch uses (the slow and once-a-drive ones too), and when.
        var latest: [String: Double] = [:]
        var latestAt: [String: Date] = [:]
        /// 0519 distance since the oil change at the last reading, km (an oil change makes it go back).
        var oilChangeKm: Double?
        /// Hot oil pressure at ~1,500 rpm: the first Tuning.oilPressureSamples qualifying readings after the
        /// oil change (or since the watch started), and the latest ones, kPa.
        var pressureBaseline: [Double] = []
        var baselineAfterOilChange = false
        var pressureRecent: [Double] = []
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
               oilPressureRecent: state.pressureRecent, injectorLearningFirst: state.learningFirst,
               latest: state.latest)
    }

    private let persist: Bool
    private var state = State()
    private var regenEntries: [DPFRegenLog.Entry] = []
    private var pmGenPer100Km: Double?

    private static let stateKey = "EngineHealth.state"

    /// The recorder's columns the watch keeps the latest value of.
    private static let kept: Set<String> = [
        "oil_dilution_g", "oil_dilution_events", "oil_change_km", "oil_pressure_kpa", "coolant_c", "oil_c",
        "intake_air_c", "ambient_c", "rail_cmd_kpa", "rail_act_kpa", "inj1_cmp_mm3", "inj2_cmp_mm3",
        "inj3_cmp_mm3", "inj4_cmp_mm3", "rpm_desired", "maf_a_gs", "maf_dsd_gs", "regen_req",
    ]

    init(persist: Bool, regenEntries: [DPFRegenLog.Entry]) {
        self.persist = persist
        self.regenEntries = regenEntries
        if persist, let data = UserDefaults.standard.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
        items = evaluate()
    }

    // MARK: Samples

    /// One recorder sample: its decoded values by CSV column, the RPM and road speed when it started.
    /// `pmGenPer100Km`: PM_GEN growth since the last regeneration, once it means something.
    func observe(_ values: [String: Double], rpm: Double?, speed: Double?, at date: Date, drive: String,
                 pmGenPer100Km: Double?, regenEntries: [DPFRegenLog.Entry]) {
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
        updateDrive(values, rpm: rpm, speed: speed, at: date, drive: drive)
        if let pressure = values["oil_pressure_kpa"], let rpm, Tuning.oilPressureRPM.contains(rpm),
           let oil = values["oil_c"], Tuning.oilPressureOilTemp.contains(oil) {
            if state.pressureBaseline.count < Tuning.oilPressureSamples { state.pressureBaseline.append(pressure) }
            state.pressureRecent.append(pressure)
            if state.pressureRecent.count > Tuning.oilPressureSamples { state.pressureRecent.removeFirst() }
        }
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

    private func updateDrive(_ values: [String: Double], rpm: Double?, speed: Double?, at date: Date, drive: String) {
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
        let regenerating = (state.latest["regen_req"] ?? 0) != 0
        if let command = values["rail_cmd_kpa"], let actual = values["rail_act_kpa"], (rpm ?? 0) >= 700 {
            stats.railSamples += 1
            stats.railGapSum += abs(actual - command) / 1000
        }
        if let rpm, let target = values["rpm_desired"], target > 0, warm, (speed ?? 1) < 1 {
            stats.idleSamples += 1
            if abs(rpm - target) > Tuning.idleDeviationRPM { stats.idleOff += 1 }
        }
        if let actual = values["maf_a_gs"], let target = values["maf_dsd_gs"], target >= Tuning.mafMinTarget,
           let rpm, Tuning.mafRPM.contains(rpm), warm, moving, !regenerating {
            stats.mafSamples += 1
            if abs(actual / target - 1) > Tuning.mafDeviation { stats.mafOff += 1 }
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
         regenInterval(), regenInterrupted(), pmGenRate(),
         airFlow()]
    }

    private static let oilGroup = "Fuel in the oil"
    private static let temperatureGroup = "Engine temperature"
    private static let fuelGroup = "Fuel system (fuel reaching the oil without a regeneration)"
    private static let regenGroup = "Regeneration (the main source of fuel in the oil)"
    private static let airGroup = "Air (more soot, more regenerations)"

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
        return Item(id: "oil_pressure", group: Self.oilGroup, title: "Hot oil pressure at ~1,500 rpm (0415)",
                    value: value,
                    range: String(format: "Mazda 140–190 kPa at 1,500 rpm (oil 70–80 °C) · watch at −%.0f kPa from "
                                  + "after the oil change · PCM: −%.0f kPa sets P253F", Tuning.oilPressureDropWatch,
                                  Tuning.oilPressureDropP253F),
                    level: level,
                    about: String(format: "EOP with the oil at %.0f–%.0f °C and %.0f–%.0f rpm, the median of the "
                                  + "last %d such readings. Fuel thins the oil, so its pressure falls as fuel builds "
                                  + "up: the PCM compares it with the value after the oil change (that's P253F). "
                                  + "0415 in kPa is FORScan's definition from other Mazda PCMs.",
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
        guard let drive = state.drives.last(where: { ($0.offHours ?? 0) >= Tuning.coldStartOffHours }) else {
            return Item(id: "cold_start", group: Self.temperatureGroup,
                        title: "Temperature sensors after a cold soak", value: "--",
                        range: coldStartRange, level: .unknown, about: coldStartAbout, advice: coldStartAdvice)
        }
        let named: [(String, Double?)] = [("coolant", drive.firstCoolant), ("oil", drive.firstOil),
                                          ("intake", drive.firstIntake), ("outside", drive.firstAmbient)]
        let readings: [(String, Double)] = named.compactMap { pair in pair.1.map { (pair.0, $0) } }
        var value = readings.map { $0.0 + " " + String(format: "%.0f", $0.1) }.joined(separator: ", ")
        var level = Level.unknown
        if readings.count >= 3, let low = readings.map(\.1).min(), let high = readings.map(\.1).max() {
            value += String(format: " °C (spread %.0f)", high - low)
            level = Self.level(high - low, watch: Tuning.coldStartSpreadWatch, high: Tuning.coldStartSpreadHigh)
        }
        return Item(id: "cold_start", group: Self.temperatureGroup, title: "Temperature sensors after a cold soak",
                    value: value, range: coldStartRange, level: level, about: coldStartAbout, advice: coldStartAdvice)
    }

    private var coldStartRange: String {
        String(format: "guide: after %.0f h off they read about the same · watch at a %.0f °C spread",
               Tuning.coldStartOffHours, Tuning.coldStartSpreadWatch)
    }
    private let coldStartAbout = "Coolant, oil, intake air and outside air at the first sample after the car stood "
        + "for hours. A coolant sensor reading low makes the PCM treat the engine as cold: more fuel, longer "
        + "glow and post injection, failed regenerations."
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
        let values = (1...4).map { state.latest["inj\($0)_cmp_mm3"] }
        let known = values.compactMap { $0 }
        return Item(id: "injector_correction", group: Self.fuelGroup, title: "Injector corrections (098A–098D)",
                    value: known.isEmpty ? "--" : values.map { $0.map { String(format: "%+.2f", $0) } ?? "--" }
                        .joined(separator: " / ") + " mm³",
                    range: String(format: "Mazda reference about ±0.3 mm³/stroke · guide: watch at ±%.1f, high at ±%.1f",
                                  Tuning.injectorCorrectionWatch, Tuning.injectorCorrectionHigh),
                    level: Self.level(known.map(abs).max(), watch: Tuning.injectorCorrectionWatch,
                                      high: Tuning.injectorCorrectionHigh),
                    about: "INJx_CMP: how much the PCM corrects each injector's quantity. One far from the others is "
                    + "a worn or dripping injector — a dripping one puts fuel in the oil without any regeneration.",
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
                    advice: "The PM_GEN growth and air flow items show why the soot builds up so fast.")
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

    private func airFlow() -> Item {
        let drive = Self.latestDrive(state.drives) { $0.mafSamples >= Tuning.mafMinSamples }
        let share = drive.map { Double($0.mafOff) / Double($0.mafSamples) }
        var level = Self.level(share, watch: Tuning.mafOffShareWatch, high: .infinity)
        if level == .high { level = .watch }
        return Item(id: "air_flow", group: Self.airGroup, title: "Air flow vs the PCM's target (F466 / 040C)",
                    value: drive.map { String(format: "%.0f %% of %d samples off by more than %.0f %%",
                                              Double($0.mafOff) * 100 / Double($0.mafSamples), $0.mafSamples,
                                              Tuning.mafDeviation * 100) } ?? "--",
                    range: String(format: "Mazda: about 5.5 g/s at idle · guide: warm, %.0f–%.0f rpm, not "
                                  + "regenerating, within %.0f %% of MAF_DSD", Tuning.mafRPM.lowerBound,
                                  Tuning.mafRPM.upperBound, Tuning.mafDeviation * 100),
                    level: level,
                    about: "The PCM steers EGR so the fresh air flow meets its target (MAF_DSD). Staying away from it "
                    + "points at the EGR valve or cooler, the MAF sensor or a boost leak — all of them make more soot.",
                    advice: "Compare EGR target / actual and boost on the DPF screen; a dirty MAF sensor or EGR valve "
                    + "is a common cause.")
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
