// MonitorSwitches.swift
// What of the car's engine data is monitored, and how fast.
//
//   switches (DPF screen > Monitored values): one per group of values and one per value. Off = not read
//     from the car and not recorded (its CSV columns stay empty). Kept in UserDefaults.
//   a regeneration: while one is starting or running, every value of a group that has to do with it is read
//     and recorded whatever its switches say (MonitorSelection.records). The switches themselves are never
//     touched, so they are back in force as soon as it's over.
//   the two values a regeneration is noticed by (0380 requests, 0432 count) are always read; with their
//     switch off they are only looked at, not recorded.
//   pace (PollPacer): the adapter answers one request at a time, 50–100 ms each, with a round of live data
//     (road speed, selector, turn signals) between the recorder's goes. The recorder measures how long its
//     reads really take and stretches its intervals when the values switched on need more of the link than
//     AppConfig.DPF.recordLinkShare, and shortens them (down to recordMinInterval) when they need less.
//
// Pure value code apart from MonitorSwitches itself (the store); used by DPFRecorder, DPFMonitor,
// DPFRegenLog and the DPF screen.

import Combine
import Foundation

/// A group of values with one switch.
nonisolated enum MonitorGroup: String, CaseIterable, Identifiable, Sendable {
    case soot, dpfPressure, exhaustTemps, airEGR, boost, fuel, oil, engine
    case trip, diagnostics, learning, transmission

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soot: return "Soot and regeneration"
        case .dpfPressure: return "DPF pressure and exhaust flow"
        case .exhaustTemps: return "Exhaust and DPF temperatures"
        case .airEGR: return "Air, EGR and intake shutter"
        case .boost: return "Boost and turbo"
        case .fuel: return "Fuel and injection"
        case .oil: return "Oil"
        case .engine: return "Engine load and coolant"
        case .trip: return "Odometer, outside air and run time"
        case .diagnostics: return "Battery and trouble codes"
        case .learning: return "Learned values"
        case .transmission: return "Gearbox (candidates)"
        }
    }

    /// Read and recorded during a regeneration whatever the switches say.
    var regenRelated: Bool {
        switch self {
        case .soot, .dpfPressure, .exhaustTemps, .airEGR, .boost, .fuel, .oil, .engine: return true
        case .trip, .diagnostics, .learning, .transmission: return false
        }
    }

    /// Which group every DID read belongs to (PCM 7E0 unless the field says otherwise).
    static let dids: [MonitorGroup: [String]] = [
        .soot: ["042D", "044B", "042C", "0380", "0432", "0434", "0381", "0433", "F48B"],
        .dpfPressure: ["F47A", "03DB", "0430", "F473", "F49E"],
        .exhaustTemps: ["F478", "F47C", "003C", "003D", "003E", "F43C", "F43E"],
        .airEGR: ["F410", "F466", "040C", "0314", "F469", "F42C", "F42D", "03FB", "F411", "F46C", "F46A", "0451",
                  "044A", "F46B", "F444", "F434", "F424", "F48C"],
        .boost: ["F470", "F40B", "F471", "F472", "03DF", "0462", "046E", "F474", "F475", "F476", "F46F", "F477",
                 "0301", "1305", "F487"],
        .fuel: ["1411", "F45E", "F49D", "F45D", "F423", "F459", "F46D", "042B", "042A", "0431", "0307",
                "098A", "098B", "098C", "098D"],
        .oil: ["F45C", "03E1", "0415", "0424", "0594", "0435", "0416", "DA01", "0519", "0542"],
        .engine: ["F404", "F405", "F461", "F462", "F449", "0308", "F463", "F467", "F443", "F465"],
        .trip: ["DD01", "F40F", "F446", "F433", "F42F", "F41F", "F468", "DD00", "F44F", "F450", "F47F"],
        .diagnostics: ["F442", "F401", "F431", "F430", "F421", "F441", "F44D", "F44E"],
        .learning: ["0436", "0437", "0438", "0439", "051A", "051E", "0534", "0538", "C968", "C969", "DAAE"],
        .transmission: ["1E1C", "1674"],
    ]

    private static let groupByDID: [String: MonitorGroup] = {
        var result: [String: MonitorGroup] = [:]
        for (group, list) in dids { for did in list { result[did] = group } }
        return result
    }()

    /// The group of `did`; nil for one that isn't listed (it then has only its own switch).
    static func of(did: String) -> MonitorGroup? { groupByDID[did] }

    /// Always read, switch off or not: the regeneration requests and count, which a regeneration is noticed by.
    static let sentinelDIDs: Set<String> = ["0380", "0432"]
}

/// The switches as they are set: everything is on unless listed here.
nonisolated struct MonitorSelection: Codable, Equatable, Sendable {
    /// Groups switched off (MonitorGroup raw values).
    var offGroups: Set<String> = []
    /// Single values switched off, by DID.
    var offDIDs: Set<String> = []
    /// The slow sweep through the PCM's DIDs (DPFRecorder), off.
    var sweepOff = false

    func isOn(_ group: MonitorGroup) -> Bool { !offGroups.contains(group.rawValue) }

    /// The value's own switch (it only counts while its group is on).
    func isOn(did: String) -> Bool { !offDIDs.contains(did) }

    /// On: its group's switch and its own.
    func monitors(did: String) -> Bool {
        if let group = MonitorGroup.of(did: did), !isOn(group) { return false }
        return isOn(did: did)
    }

    /// Whether `did` is read and recorded now: switched on, or a regeneration is under way and it has to do
    /// with one.
    func records(did: String, regenActive: Bool) -> Bool {
        if monitors(did: did) { return true }
        return regenActive && (MonitorGroup.of(did: did)?.regenRelated ?? false)
    }

    /// Whether `did` is asked for at all: recorded, or one of the two a regeneration is noticed by.
    func polls(did: String, regenActive: Bool) -> Bool {
        records(did: did, regenActive: regenActive) || MonitorGroup.sentinelDIDs.contains(did)
    }

    mutating func set(_ group: MonitorGroup, on: Bool) {
        if on { offGroups.remove(group.rawValue) } else { offGroups.insert(group.rawValue) }
    }

    mutating func set(did: String, on: Bool) {
        if on { offDIDs.remove(did) } else { offDIDs.insert(did) }
    }
}

/// The switches, kept between launches (UserDefaults).
final class MonitorSwitches: ObservableObject {

    static let shared = MonitorSwitches()

    @Published var selection: MonitorSelection {
        didSet {
            guard selection != oldValue else { return }
            defaults.setCodable(selection, forKey: key)
        }
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "monitor.switches") {
        self.defaults = defaults
        self.key = key
        selection = defaults.codable(MonitorSelection.self, forKey: key) ?? MonitorSelection()
    }

    /// Everything on again.
    func reset() {
        selection = MonitorSelection()
    }
}

/// Works out how often the recorder samples from how much it has to read and how fast the link answers.
nonisolated struct PollPacer: Equatable, Sendable {

    /// What one sample of each tier costs, in reads: a single-frame reply 1, one of several frames 3, and
    /// the RPM read every go starts with.
    nonisolated struct Costs: Equatable, Sendable {
        var fast = 0.0
        var normal = 0.0
        var slow = 0.0
    }

    /// The limits and the intervals to start from.
    nonisolated struct Limits: Equatable, Sendable {
        /// Intervals when the link has just enough room: every sample, the 30 s and the 2 min values.
        var fast: TimeInterval
        var normal: TimeInterval
        var slow: TimeInterval
        /// Never sampled more often than this, however little is switched on…
        var minFast: TimeInterval
        /// …and never less often than this, however much.
        var maxFast: TimeInterval
        /// The 30 s and 2 min values are stretched by at most this factor.
        var maxStretch: Double
        /// The part of the link's time the recorder may use (the rest is live data's).
        var share: Double
    }

    nonisolated struct Plan: Equatable, Sendable {
        var fast: TimeInterval
        var normal: TimeInterval
        var slow: TimeInterval
        /// The part of the link's time the recorder would use at the intervals it started from (over the
        /// share: stretched; under it: sampled faster).
        var demand: Double
    }

    /// Seconds one read takes, live data's round between two goes included: measured, smoothed.
    private(set) var secondsPerRead: TimeInterval
    private(set) var measured = false

    /// What a read is taken to cost before anything was measured, and how quickly new measurements count.
    private let smoothing: Double
    private static let plausible: ClosedRange<TimeInterval> = 0.02...2.0

    init(secondsPerRead: TimeInterval, smoothing: Double = 0.25) {
        self.secondsPerRead = secondsPerRead
        self.smoothing = smoothing
    }

    /// A sample of `reads` (in the units of Costs) took `seconds` from its first request to its last reply.
    mutating func observe(seconds: TimeInterval, reads: Double) {
        guard reads >= 1, seconds > 0 else { return }
        let one = min(max(seconds / reads, Self.plausible.lowerBound), Self.plausible.upperBound)
        secondsPerRead = measured ? secondsPerRead + (one - secondsPerRead) * smoothing : one
        measured = true
    }

    /// The intervals for `costs`. Too much for the link's share: every interval is stretched by the same
    /// factor. Room to spare: the every-sample values come more often, down to `minFast`; the 30 s and 2 min
    /// values keep their pace.
    func plan(_ costs: Costs, limits: Limits) -> Plan {
        let rest = secondsPerRead * (costs.normal / limits.normal + costs.slow / limits.slow)
        let demand = rest + secondsPerRead * costs.fast / limits.fast
        guard demand > limits.share else {
            var fast = limits.fast
            if costs.fast > 0 {
                fast = Self.wholeSeconds(secondsPerRead * costs.fast / (limits.share - rest))
            }
            fast = min(limits.fast, max(limits.minFast, fast))
            return Plan(fast: fast, normal: limits.normal, slow: limits.slow, demand: demand)
        }
        let stretch = demand / limits.share
        let fast = min(limits.maxFast, Self.wholeSeconds(limits.fast * stretch))
        let slower = min(stretch, limits.maxStretch)
        return Plan(fast: fast, normal: max(fast, Self.wholeSeconds(limits.normal * slower)),
                    slow: max(fast, Self.wholeSeconds(limits.slow * slower)), demand: demand)
    }

    /// Up to the next whole second (26.000000001 is 26).
    private static func wholeSeconds(_ seconds: TimeInterval) -> TimeInterval {
        (seconds - 1e-6).rounded(.up)
    }
}
