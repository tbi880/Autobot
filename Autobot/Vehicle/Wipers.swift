// Wipers.swift
// The windshield wipers as the car tells them over HS-CAN, and how this car's bits are found. Pure value
// code (no Bluetooth): OBDAdapter hears the frame and reads the front body control module, WiperFinder
// runs the checks, RainMode decides.
//
// Two different things, from two places:
//
// 1. The lever (OFF / AUTO or INT / LO / HI) and the washer: frame 0x09A, the start stop unit's
//    steering-column switch frame, which the turn signals come from too. OBDAdapter listens to it every
//    round anyway, so the lever costs no adapter time at all. CX-5 workshop manual: the start stop unit
//    "detects a windshield wiper switch signal" and sends the "windshield wiper switch position signal …
//    to the front body control module (FBCM) as a CAN signal". Its own PIDs show the switch is two
//    contacts: WIP_F_INT (on in AUTO/INT and HI) and WIP_F_LOW (on in MIST, LO and HI). openpilot's
//    mazda_2017.dbc (CX-5 2017+) has two wiper bits in 0x09A, byte 4: WIPER_LO (0x02) and WIPER_HI
//    (0x04). Read together, 0x02 is the LO contact and 0x04 the INT contact (openpilot only saw it
//    together with HI), so
//
//        lever       byte 4 & 06
//        OFF         00
//        AUTO / INT  04
//        LO, MIST    02
//        HI          06
//
//    That's the built-in layout (WiperLeverLayout.builtIn). The lever check (WiperLeverLayout.learn)
//    confirms it on this car, or finds the bits this car uses instead: the smallest set of frame bits
//    that tells the four positions apart, byte 4's two bits first.
//
// 2. Whether the wipers really wipe, needed in AUTO / INT only (there the rain sensor, or the INT timer,
//    decides). The FBCM (726, replies from 72E) drives the wiper relays and reads the motor's auto-stop
//    switch (workshop manual PIDs WIP_F_RY_LO / WIP_F_RY_HI / WIP_F_MST), but no public source has their
//    DIDs, so the bit is found on the car (WiperMotorAnalysis):
//      - parked (lever OFF) vs wiping (lever LO): the bits that read differently. That's what the earlier
//        wiper finder stopped at, and it always left 9–10 equally good candidates, because with the lever
//        in LO everything wiper-related changes at once: the FBCM's copy of the lever, "LO requested",
//        both relays, the auto-stop switch, often in more than one DID;
//      - so a trace decides: the DIDs of those candidates are read over and over while the lever goes
//        OFF -> AUTO, which wipes exactly once while the lever stays in AUTO. The motor and relay bits
//        leave their parked value with that one wipe and come back; the lever copy changes and stays;
//        "LO requested" and the washer never move. Only bits that come and go right after "NOW", for about
//        a wipe, count (a slow counter bit or a drifting value comes and goes at other times). Best first:
//        in the most traces, together with the most other bits (one wipe moves them all at once), away
//        the longest (the auto-stop switch covers the whole wipe). Bits of the same byte that did the same
//        are read together, other DIDs that did the same are only listed. There is always one answer.

import Foundation

// MARK: - Shared

/// Small helpers for the wiper code.
nonisolated enum Wipers {
    /// "06"
    static func hex(_ byte: UInt8) -> String { String(format: "%02X", byte) }
    /// "00 00 08 00 04 00 00 00"
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// The windshield wiper lever.
nonisolated enum WiperLever: String, Codable, CaseIterable, Identifiable {
    case off, auto, low, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "OFF"
        case .auto: return "AUTO / INT"
        case .low: return "LO"
        case .high: return "HI"
        }
    }
}

/// Some bits of one byte of a frame and the value they have: "byte 3 & 01 = 01".
nonisolated struct FrameBits: Codable, Equatable {
    var byte: Int
    var mask: UInt8
    var value: UInt8

    func matches(_ data: [UInt8]) -> Bool {
        byte < data.count && (data[byte] & mask) == value
    }

    var label: String {
        "byte \(byte) & " + Wipers.hex(mask) + " = " + Wipers.hex(value)
    }
}

// MARK: - The lever, in frame 0x09A

/// Where this car keeps the wiper lever (and the washer) in frame 0x09A: a few bits (`fields`), and which
/// value of them is which lever position (`codes`).
nonisolated struct WiperLeverLayout: Codable, Equatable {

    /// The lever bits of one byte.
    nonisolated struct Field: Codable, Equatable, Hashable {
        var byte: Int
        var mask: UInt8
    }

    /// Every field's value (only its mask's bits) in one lever position.
    nonisolated struct Code: Codable, Equatable {
        var values: [UInt8]
        var lever: WiperLever
    }

    var fields: [Field]
    /// One per lever position, in WiperLever.allCases order.
    var codes: [Code]
    /// The washer's own bits (all of them must match); nil while not known.
    var washer: [FrameBits]?
    /// Confirmed on this car by the lever check; false for the built-in layout.
    var checked: Bool

    /// Until the lever check has run: byte 4, 0x02 the LO contact, 0x04 the INT contact (top of this file).
    static let builtIn = WiperLeverLayout(
        fields: [Field(byte: 4, mask: 0x06)],
        codes: [Code(values: [0x00], lever: .off), Code(values: [0x04], lever: .auto),
                Code(values: [0x02], lever: .low), Code(values: [0x06], lever: .high)],
        washer: nil,
        checked: false)

    /// The fields' values in a frame; nil if the frame is too short.
    func code(in data: [UInt8]) -> [UInt8]? {
        guard !fields.isEmpty, fields.allSatisfy({ $0.byte < data.count }) else { return nil }
        return fields.map { data[$0.byte] & $0.mask }
    }

    /// The lever position a frame shows; nil when its code is none of the known ones (the lever between
    /// two positions, or bits this layout doesn't know).
    func lever(in data: [UInt8]) -> WiperLever? {
        guard let code = code(in: data) else { return nil }
        return codes.first { $0.values == code }?.lever
    }

    /// Whether the washer is in use in this frame (as far as its bits are known).
    func isWashing(_ data: [UInt8]) -> Bool {
        guard let washer, !washer.isEmpty else { return false }
        return washer.allSatisfy { $0.matches(data) }
    }

    /// The lever bits of a frame as hex ("04"), for logs and screens.
    func codeText(_ data: [UInt8]) -> String {
        code(in: data).map { Wipers.hex($0) } ?? "--"
    }

    /// Where the lever bits are: "byte 4 & 06".
    var placeLabel: String {
        fields.map { "byte \($0.byte) & " + Wipers.hex($0.mask) }.joined(separator: ", ")
    }

    /// For the screens: "byte 4 & 06: OFF 00 · AUTO / INT 04 · LO 02 · HI 06", "Washer: byte 3 & 01 = 01".
    var descriptions: [String] {
        let values = WiperLever.allCases.compactMap { lever -> String? in
            guard let code = codes.first(where: { $0.lever == lever }) else { return nil }
            return lever.label + " " + Wipers.hex(code.values)
        }
        var lines = [placeLabel + ": " + values.joined(separator: " · ")]
        if let washer, !washer.isEmpty {
            lines.append("Washer: " + washer.map(\.label).joined(separator: ", "))
        }
        return lines
    }
}

// MARK: Lever check

nonisolated extension WiperLeverLayout {

    /// A step of the lever check: a lever position, or the washer (lever OFF, pulled towards you and held).
    nonisolated enum Step: String, Codable, CaseIterable, Identifiable {
        case off, auto, low, high, washer

        var id: String { rawValue }

        var lever: WiperLever? {
            switch self {
            case .off: return .off
            case .auto: return .auto
            case .low: return .low
            case .high: return .high
            case .washer: return nil
            }
        }

        var label: String { lever?.label ?? "Washer" }
    }

    /// What the lever check makes of the frames: the layout (nil until OFF, AUTO / INT, LO and HI are told
    /// apart) and what to look out for.
    nonisolated struct CheckResult: Equatable {
        var layout: WiperLeverLayout?
        var notes: [String] = []

        /// The check found the built-in layout (byte 4: 0x02 LO contact, 0x04 INT contact).
        var matchesBuiltIn: Bool {
            guard let layout else { return false }
            return layout.fields == WiperLeverLayout.builtIn.fields && layout.codes == WiperLeverLayout.builtIn.codes
        }
    }

    /// At most this many candidate bits are tried in combination (best first).
    private static let maxCandidateBits = 12
    /// A lever layout never needs more bits than this.
    private static let maxLeverBits = 4

    /// Learns the layout from the frames heard in each step (`takes[step]`: one list of frames per take;
    /// several takes of a step are fine, OFF at the start and again at the end is best).
    ///
    /// The lever bits are the smallest set of bits that keep their value within every position and tell
    /// OFF from the rest and AUTO / INT from LO and HI (LO from HI too, if they can), byte 4's two bits
    /// first, then bits of bytes where little else changes. Everything else that happened to differ
    /// between the takes (a light, a checksum byte) is left out: had it been kept, the lever would be
    /// unreadable as soon as that light changed. `ignored` bits by byte (the indicator lamps) never count.
    static func learn(_ takes: [Step: [[[UInt8]]]], ignored: [Int: UInt8]) -> CheckResult {
        var looks: [WiperLever: Look] = [:]
        for step in Step.allCases {
            guard let lever = step.lever, let frames = takes[step], let look = Look(frames.flatMap { $0 }) else {
                continue
            }
            looks[lever] = look
        }
        var result = CheckResult()
        let levers = WiperLever.allCases
        let missing = levers.filter { looks[$0] == nil }
        guard missing.isEmpty else {
            result.notes = ["Still to take: " + missing.map(\.label).joined(separator: ", ") + "."]
            return result
        }
        let all = levers.compactMap { looks[$0] }
        let length = all.map(\.values.count).min() ?? 0

        // Bits that keep their value within every position and differ between some of them, and how
        // many such bits each byte has (a lever byte has one or two, a checksum or a value many).
        var candidates: [Bit] = []
        var changing = [Int](repeating: 0, count: length)
        for byte in 0..<length {
            for shift in 0..<8 {
                let mask = UInt8(1) << UInt8(shift)
                if ((ignored[byte] ?? 0) & mask) != 0 { continue }
                guard all.allSatisfy({ ($0.steady[byte] & mask) != 0 }) else { continue }
                guard Set(all.map { $0.values[byte] & mask }).count > 1 else { continue }
                candidates.append(Bit(byte: byte, mask: mask))
                changing[byte] += 1
            }
        }
        guard !candidates.isEmpty else {
            result.notes = ["No bit of frame 09A keeps one value per lever position and changes with the "
                            + "lever: take the steps again with the lever right in each detent, or export the "
                            + "raw frames."]
            return result
        }
        let preferred = WiperLeverLayout.builtIn.fields
        func isPreferred(_ bit: Bit) -> Bool {
            preferred.contains { $0.byte == bit.byte && ($0.mask & bit.mask) != 0 }
        }
        candidates.sort { a, b in
            if isPreferred(a) != isPreferred(b) { return isPreferred(a) }
            if changing[a.byte] != changing[b.byte] { return changing[a.byte] < changing[b.byte] }
            if a.byte != b.byte { return a.byte < b.byte }
            return a.mask < b.mask
        }
        let pool = Array(candidates.prefix(maxCandidateBits))

        // The pairs that must read differently, and the one that should (LO and HI are both rain).
        let mustDiffer: [(WiperLever, WiperLever)] = [(.off, .auto), (.off, .low), (.off, .high),
                                                      (.auto, .low), (.auto, .high)]
        let shouldDiffer: [(WiperLever, WiperLever)] = [(.low, .high)]

        /// Each position's value of `subset`.
        func valuesOf(_ subset: [Bit]) -> [WiperLever: [UInt8]] {
            var values: [WiperLever: [UInt8]] = [:]
            for lever in levers {
                guard let look = looks[lever] else { continue }
                values[lever] = subset.map { look.values[$0.byte] & $0.mask }
            }
            return values
        }

        var best: (subset: [Bit], must: Int, should: Int, score: Int)?
        for subset in subsets(of: pool, maxSize: maxLeverBits) {
            let values = valuesOf(subset)
            let must = mustDiffer.filter { values[$0.0] != values[$0.1] }.count
            let should = shouldDiffer.filter { values[$0.0] != values[$0.1] }.count
            let score = preference(of: subset, isPreferred: isPreferred, changing: changing)
            if let current = best {
                let better: Bool
                if must != current.must {
                    better = must > current.must
                } else if should != current.should {
                    better = should > current.should
                } else if subset.count != current.subset.count {
                    better = subset.count < current.subset.count
                } else {
                    better = score > current.score
                }
                if !better { continue }
            }
            best = (subset: subset, must: must, should: should, score: score)
        }
        guard let best else { return result }
        guard best.must == mustDiffer.count else {
            let values = valuesOf(best.subset)
            let same = mustDiffer.filter { values[$0.0] == values[$0.1] }.map { "\($0.0.label) and \($0.1.label)" }
            result.notes = ["These read the same in frame 09A: " + same.joined(separator: ", ")
                            + ". Take them again with the lever right in the detent, or export the raw frames."]
            return result
        }

        // The chosen bits, byte by byte, and each position's value of them.
        var masks: [Int: UInt8] = [:]
        for bit in best.subset { masks[bit.byte, default: 0] |= bit.mask }
        let fields = masks.keys.sorted().map { Field(byte: $0, mask: masks[$0] ?? 0) }
        let table = levers.compactMap { lever -> Code? in
            guard let look = looks[lever] else { return nil }
            return Code(values: fields.map { look.values[$0.byte] & $0.mask }, lever: lever)
        }
        var layout = WiperLeverLayout(fields: fields, codes: table, washer: nil, checked: true)
        if best.should < shouldDiffer.count {
            result.notes.append("LO and HI read the same here: both are rain, the screen shows LO.")
        }

        // The washer: a bit of its own (steady while washing and with the lever OFF, different between the
        // two, not a lever bit), the cleanest one if there are several.
        if let washerFrames = takes[.washer], let washing = Look(washerFrames.flatMap { $0 }), let off = looks[.off] {
            if let washCode = layout.code(in: washing.values),
               let reads = layout.codes.first(where: { $0.values == washCode })?.lever, reads != .off {
                result.notes.append("The washer reads like \(reads.label) in the lever bits: while it's pulled, "
                                    + "the lever is left as it was.")
            }
            let n = min(washing.values.count, off.values.count)
            var washerBits: [Bit] = []
            for byte in 0..<n {
                let differ = washing.steady[byte] & off.steady[byte] & (washing.values[byte] ^ off.values[byte])
                    & ~(masks[byte] ?? 0) & ~(ignored[byte] ?? 0)
                for shift in 0..<8 where (differ & (UInt8(1) << UInt8(shift))) != 0 {
                    washerBits.append(Bit(byte: byte, mask: UInt8(1) << UInt8(shift)))
                }
            }
            var perByte: [Int: Int] = [:]
            for bit in washerBits { perByte[bit.byte, default: 0] += 1 }
            let cleanest = washerBits.min { a, b in
                let ka = perByte[a.byte] ?? 0, kb = perByte[b.byte] ?? 0
                if ka != kb { return ka < kb }
                if a.byte != b.byte { return a.byte < b.byte }
                return a.mask < b.mask
            }
            if let bit = cleanest {
                layout.washer = [FrameBits(byte: bit.byte, mask: bit.mask, value: washing.values[bit.byte] & bit.mask)]
            } else {
                result.notes.append("The washer has no bit of its own in frame 09A: its wipes in AUTO may count as rain.")
            }
        } else {
            result.notes.append("Washer not taken (optional): without it, the washer's wipes in AUTO aren't told from rain.")
        }
        if (takes[.off]?.count ?? 0) < 2 {
            result.notes.append("Take OFF once more at the end: anything that changes by itself then drops out.")
        }
        result.layout = layout
        return result
    }

    // MARK: Helpers

    /// One bit of one byte.
    fileprivate nonisolated struct Bit: Hashable {
        let byte: Int
        let mask: UInt8
    }

    /// Higher is better: byte 4's built-in bits, few bytes, and bytes where the chosen bits are all that
    /// changes.
    private static func preference(of subset: [Bit], isPreferred: (Bit) -> Bool, changing: [Int]) -> Int {
        let bytes = Set(subset.map(\.byte))
        var score = subset.filter { isPreferred($0) }.count * 10
        score -= (bytes.count - 1) * 3
        score -= bytes.reduce(0) { $0 + changing[$1] } - subset.count
        return score
    }

    /// Every subset of `items` with 1…maxSize elements, smaller ones first, in order.
    private static func subsets<T>(of items: [T], maxSize: Int) -> [[T]] {
        var result: [[T]] = []
        func extend(_ current: [T], from start: Int, size: Int) {
            if current.count == size {
                result.append(current)
                return
            }
            guard start < items.count else { return }
            for i in start..<items.count {
                extend(current + [items[i]], from: i + 1, size: size)
            }
        }
        let largest = min(maxSize, items.count)
        guard largest > 0 else { return [] }
        for size in 1...largest { extend([], from: 0, size: size) }
        return result
    }

    /// What a set of frames has in common: the first frame's bytes, and per byte the bits that never change
    /// (over the length all frames have).
    fileprivate nonisolated struct Look {
        let values: [UInt8]
        let steady: [UInt8]

        init?(_ frames: [[UInt8]]) {
            guard let first = frames.first, let length = frames.map(\.count).min(), length > 0 else { return nil }
            let values = Array(first.prefix(length))
            var changing = [UInt8](repeating: 0, count: length)
            for frame in frames {
                for i in 0..<length { changing[i] |= frame[i] ^ values[i] }
            }
            self.values = values
            steady = changing.map { ~$0 }
        }
    }
}

// MARK: - The wiper motor, in the front body control module

/// The FBCM bit(s) that say the wipers are moving: some bits of one byte of one DID, and their value with
/// the wipers parked. Anything else there means wiping.
nonisolated struct WiperMotorSignal: Codable, Equatable {
    /// "726"
    var header: String
    /// "DA0B"
    var did: String
    /// Byte in the data after "62 <DID>".
    var byteIndex: Int
    /// One bit, or several bits of the same byte that came and went together with the wipe.
    var mask: UInt8
    /// byte & mask with the wipers parked.
    var parked: UInt8
    /// Data bytes the DID returns (up to 4 fit one CAN frame).
    var length: Int

    /// "726 DA0B"
    var key: String { "\(header) \(did)" }

    /// true = wiping, false = parked, nil = no (usable) reply.
    func isWiping(_ data: [UInt8]?) -> Bool? {
        guard let data, byteIndex < data.count else { return nil }
        return (data[byteIndex] & mask) != parked
    }

    /// "726 22DA0B byte 2 & 10 (parked 00)"
    var label: String {
        "\(header) 22\(did) byte \(byteIndex) & " + Wipers.hex(mask) + " (parked " + Wipers.hex(parked) + ")"
    }
}

/// Finds the wiper motor bit among the FBCM's DIDs; WiperFinder collects the reads, this decides.
nonisolated enum WiperMotorAnalysis {

    /// Every read of one snapshot, by DID ("726 DA0B" -> [first read, second read, …]).
    typealias Snapshot = SignalDiff.Snapshot

    /// One read during a trace: when (seconds from the start of the trace), which DID, what came back.
    nonisolated struct Sample: Codable, Equatable {
        var time: TimeInterval
        var key: String
        var data: [UInt8]
    }

    /// A bit that reads one way with the wipers parked (lever OFF) and the other way while they wipe (LO).
    nonisolated struct Candidate: Equatable, Identifiable {
        /// "726 DA0B"
        let key: String
        let byteIndex: Int
        let bit: UInt8
        /// The bit's value parked: 0 or `bit`.
        let parked: UInt8
        let length: Int
        /// Higher is likelier, from parked vs wiping alone: the whole byte steady parked, away from parked in
        /// every read while wiping, at most two such bits in its byte, the only byte of its DID that changes.
        let score: Int

        var id: String { "\(key)#\(byteIndex)#\(bit)" }
        var header: String { String(key.prefix { $0 != " " }) }
        var did: String { String(key.drop { $0 != " " }.dropFirst()) }
        /// "726 DA0B byte 2 bit 10"
        var label: String { "\(key) byte \(byteIndex) bit " + Wipers.hex(bit) }
    }

    /// What one candidate bit did during one trace.
    nonisolated enum Behaviour: Equatable {
        /// Left its parked value once, early in the trace (at `start`), for about a wipe, and was back there
        /// for the whole end of the trace: it moved with the wipe.
        case pulse(awayReads: Int, start: TimeInterval)
        /// Still away from parked at the end: it followed the lever (or the trace ended mid-wipe).
        case stepped
        /// Never left its parked value.
        case flat
        /// Came and went, but not like the one wipe: too late after the start, or away too long (a slow
        /// counter bit, a drifting value — or the lever moved late in this trace).
        case offTime
        /// Changed back and forth too often to be a wipe.
        case flickering
        /// Not read often enough in this trace to tell.
        case tooFewReads
    }

    /// How a trace is judged (AppConfig.Rain).
    nonisolated struct TraceTiming: Equatable {
        /// A bit has to be back at its parked value for at least this long at the end.
        var settle: TimeInterval
        /// The wipe starts within this long after the trace started: the lever goes to AUTO right after "NOW".
        var moveWindow: TimeInterval
        /// …and is over within this long (one wipe takes about a second).
        var maxWipe: TimeInterval
    }

    /// The outcome so far.
    nonisolated struct Result: Equatable {
        /// What to read: the best candidate that came and went with the wipe, together with any other bit of
        /// the same byte that did the same. nil until a trace shows one.
        var signal: WiperMotorSignal?
        /// In how many traces the best candidate came and went.
        var bestPulses = 0
        /// Every candidate that came and went with a wipe (and never stayed changed or flickered more often
        /// than that), best first.
        var pulsing: [Candidate] = []
        /// Other DIDs with bits that did the same (the same wiper state elsewhere in the FBCM): not needed.
        var alternatives: [String] = []
        /// Traces taken.
        var traces = 0
        var notes: [String] = []
    }

    /// A candidate needs this many reads in a trace for a say.
    static let minReadsPerTrace = 4
    /// One wipe is one stretch of reads away from parked; two allows for a read in the middle of it that
    /// came back parked (or a second INT wipe). More is noise.
    static let maxRunsPerTrace = 2
    /// A wipe changes a bit twice. More changes than this (or than every other read) is noise.
    static let maxChangesPerTrace = 6

    // MARK: Parked vs wiping

    /// The bits that are steady in every parked read and away from that value in at least half of the reads
    /// while wiping (the auto-stop switch passes its parked position once a wipe, so "every read" would lose
    /// it). `ignored` DIDs are left out. Best first.
    static func candidates(parked: [Snapshot], wiping: [Snapshot], ignored: Set<String>) -> [Candidate] {
        guard let firstParked = parked.first, !wiping.isEmpty else { return [] }
        var keys = Set(firstParked.filter { !$0.value.isEmpty }.keys)
        for snapshot in parked + wiping {
            keys.formIntersection(snapshot.filter { !$0.value.isEmpty }.keys)
        }
        keys.subtract(ignored)

        var result: [Candidate] = []
        for key in keys {
            let parkedReads = parked.flatMap { $0[key] ?? [] }
            let wipingReads = wiping.flatMap { $0[key] ?? [] }
            guard let reference = parkedReads.first, !wipingReads.isEmpty,
                  let length = (parkedReads + wipingReads).map(\.count).min(), length > 0 else { continue }
            var found: [(byte: Int, bit: UInt8, always: Bool, wholeByteSteady: Bool)] = []
            for byte in 0..<length {
                let steadyParked = SignalDiff.steadyBits(parkedReads.map { $0[byte] })
                for shift in 0..<8 {
                    let bit = UInt8(1) << UInt8(shift)
                    guard (steadyParked & bit) != 0 else { continue }
                    let parkedValue = reference[byte] & bit
                    let away = wipingReads.filter { ($0[byte] & bit) != parkedValue }.count
                    guard away > 0, away * 2 >= wipingReads.count else { continue }
                    found.append((byte: byte, bit: bit, always: away == wipingReads.count,
                                  wholeByteSteady: steadyParked == 0xFF))
                }
            }
            let changedBytes = Set(found.map { $0.byte }).count
            for entry in found {
                let inByte = found.filter { $0.byte == entry.byte }.count
                var score = 0
                if entry.wholeByteSteady { score += 3 }
                if entry.always { score += 2 }
                if inByte <= 2 { score += 1 }
                if changedBytes == 1 { score += 1 }
                result.append(Candidate(key: key, byteIndex: entry.byte, bit: entry.bit,
                                        parked: reference[entry.byte] & entry.bit, length: length, score: score))
            }
        }
        return result.sorted(by: rankedBefore)
    }

    /// Best first: score, then by DID, byte and bit.
    static func rankedBefore(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.key != b.key { return a.key < b.key }
        if a.byteIndex != b.byteIndex { return a.byteIndex < b.byteIndex }
        return a.bit < b.bit
    }

    /// The DIDs to trace, with the data length to ask for, at most `limit` (each is read once per pass, so
    /// fewer DIDs time the wipe more finely). While the best bit so far came and went in every trace (`after`),
    /// only the DIDs of the bits that came and went: the next trace reads those more often, to confirm them
    /// and time them better. Otherwise (no trace yet, or one that didn't show it) every DID with candidates,
    /// best first, so a bit an earlier trace missed gets its chance again.
    static func traceKeys(_ candidates: [Candidate], after result: Result? = nil,
                          limit: Int) -> [(key: String, length: Int)] {
        if let result, result.bestPulses > 0, result.bestPulses == result.traces, !result.pulsing.isEmpty {
            let pulsing = result.pulsing
            var keys: [(key: String, length: Int)] = []
            for candidate in pulsing where !keys.contains(where: { $0.key == candidate.key }) {
                keys.append((key: candidate.key, length: candidate.length))
            }
            return Array(keys.prefix(max(limit, 1)))
        }
        var byKey: [String: (score: Int, count: Int, length: Int)] = [:]
        for candidate in candidates {
            let current = byKey[candidate.key] ?? (score: Int.min, count: 0, length: candidate.length)
            byKey[candidate.key] = (score: max(current.score, candidate.score), count: current.count + 1,
                                    length: candidate.length)
        }
        let ranked = byKey.sorted { a, b in
            let rankA = a.value.score + min(a.value.count, 3)
            let rankB = b.value.score + min(b.value.count, 3)
            return rankA != rankB ? rankA > rankB : a.key < b.key
        }
        return ranked.prefix(max(limit, 1)).map { (key: $0.key, length: $0.value.length) }
    }

    // MARK: Traces

    /// How `candidate` behaved in `trace` (times in seconds from the start of the trace, i.e. from "NOW").
    /// A pulse: away from parked in one stretch of reads (two at most), starting within `moveWindow`, over
    /// within `maxWipe`, and parked again for the candidate's reads in the last `settle` seconds.
    static func behaviour(of candidate: Candidate, in trace: [Sample], timing: TraceTiming) -> Behaviour {
        let reads = trace.filter { $0.key == candidate.key && candidate.byteIndex < $0.data.count }
            .sorted { $0.time < $1.time }
        guard reads.count >= minReadsPerTrace, let last = reads.last else { return .tooFewReads }
        let values = reads.map { $0.data[candidate.byteIndex] & candidate.bit }
        let awayAt = values.indices.filter { values[$0] != candidate.parked }
        guard let firstAway = awayAt.first, let lastAway = awayAt.last else { return .flat }
        var changes = 0
        for i in 1..<values.count where values[i] != values[i - 1] { changes += 1 }
        if changes > max(maxChangesPerTrace, values.count / 2) { return .flickering }
        // Every read after lastAway is parked, so it's back at the end if lastAway is before the tail.
        guard reads[lastAway].time < last.time - timing.settle else { return .stepped }
        let runs = awayAt.filter { $0 == 0 || values[$0 - 1] == candidate.parked }.count
        if runs > maxRunsPerTrace { return .flickering }
        // The wipers are parked when the trace starts (lever OFF until NOW): away from the first read on is
        // something else (a counter that happened to roll over), as is a wipe that starts late or lasts long.
        let start = reads[firstAway].time
        if firstAway == 0 || start > timing.moveWindow || reads[lastAway].time - start > timing.maxWipe {
            return .offTime
        }
        return .pulse(awayReads: awayAt.count, start: start)
    }

    /// Two wiper bits of one wipe (relay, auto-stop switch, their copies) leave parked within this long of
    /// each other.
    static let sameWipe: TimeInterval = 0.6

    /// Picks the motor bit. A candidate counts once it came and went with the wipe in some trace, more often
    /// than it stayed changed or flickered (a trace that missed the wipe, or where the lever moved late, has
    /// no say). Best first: in the most traces; then together with the most other bits (everything the one
    /// wipe moves goes at the same moment, a counter bit that happened to fit does on its own); then away
    /// from parked the longest (the auto-stop switch covers the whole wipe, a relay may be on for a moment
    /// only: the longer one is caught more surely by a read every couple of seconds); then the
    /// parked-vs-wiping score.
    static func solve(candidates: [Candidate], traces: [[Sample]], timing: TraceTiming) -> Result {
        var result = Result()
        result.traces = traces.count
        guard !candidates.isEmpty, !traces.isEmpty else { return result }

        // Every candidate in every trace, and when each pulse started.
        var outcomes: [String: [Behaviour]] = [:]
        var starts: [[(id: String, time: TimeInterval)]] = Array(repeating: [], count: traces.count)
        var seen: [Behaviour] = []
        for candidate in candidates {
            var list: [Behaviour] = []
            for (index, trace) in traces.enumerated() {
                let outcome = Self.behaviour(of: candidate, in: trace, timing: timing)
                list.append(outcome)
                seen.append(outcome)
                if case .pulse(_, let start) = outcome {
                    starts[index].append((id: candidate.id, time: start))
                }
            }
            outcomes[candidate.id] = list
        }

        var pulses: [String: Int] = [:]
        var together: [String: Int] = [:]
        var awayReads: [String: Int] = [:]
        var pulsing: [Candidate] = []
        for candidate in candidates {
            var pulsed = 0
            var against = 0
            var away = 0
            var company = 0
            for (index, outcome) in (outcomes[candidate.id] ?? []).enumerated() {
                switch outcome {
                case .pulse(let reads, let start):
                    pulsed += 1
                    away += reads
                    company += starts[index].filter {
                        $0.id != candidate.id && abs($0.time - start) <= sameWipe
                    }.count
                case .stepped, .flickering:
                    against += 1
                case .flat, .offTime, .tooFewReads:
                    break                                      // missed the wipe, or not read: no say
                }
            }
            if pulsed > 0, pulsed > against {
                pulsing.append(candidate)
                pulses[candidate.id] = pulsed
                together[candidate.id] = company
                awayReads[candidate.id] = away
            }
        }
        pulsing.sort { a, b in
            let pa = pulses[a.id] ?? 0, pb = pulses[b.id] ?? 0
            if pa != pb { return pa > pb }
            let ta = together[a.id] ?? 0, tb = together[b.id] ?? 0
            if ta != tb { return ta > tb }
            let ra = awayReads[a.id] ?? 0, rb = awayReads[b.id] ?? 0
            return ra != rb ? ra > rb : rankedBefore(a, b)
        }
        result.pulsing = pulsing

        guard let best = pulsing.first else {
            if seen.allSatisfy({ $0 == .tooFewReads }) {
                result.notes = ["The FBCM answered too few times during the trace to time a wipe. Trace again."]
            } else if seen.contains(.offTime) {
                result.notes = ["Bits came and went, but not right after NOW: move the lever to AUTO as soon as it "
                                + "says NOW, and trace again."]
            } else if seen.contains(.stepped) {
                result.notes = ["Only bits that stayed changed (the FBCM's copy of the lever, or a wipe still "
                                + "running at the end). Trace again: lever to AUTO right after NOW, and keep it "
                                + "there until the trace ends."]
            } else {
                result.notes = ["No candidate moved with the wipe. Did the wipers wipe once? Lever OFF → AUTO right "
                                + "after NOW (with INT: the ring on the slowest setting). Or take Wiping again."]
            }
            return result
        }
        let bestPulses = pulses[best.id] ?? 0
        // Bits of the same byte that came and went in as many traces: read together (any of them away = wiping).
        let sameByte = pulsing.filter {
            $0.key == best.key && $0.byteIndex == best.byteIndex && (pulses[$0.id] ?? 0) == bestPulses
        }
        result.signal = WiperMotorSignal(header: best.header, did: best.did, byteIndex: best.byteIndex,
                                         mask: sameByte.reduce(UInt8(0)) { $0 | $1.bit },
                                         parked: sameByte.reduce(UInt8(0)) { $0 | $1.parked },
                                         length: best.length)
        result.bestPulses = bestPulses
        var others: [String] = []
        for candidate in pulsing where candidate.key != best.key && (pulses[candidate.id] ?? 0) == bestPulses
            && !others.contains(candidate.key) {
            others.append(candidate.key)
        }
        result.alternatives = others
        if bestPulses < 2 {
            result.notes.append("Trace once more to confirm: the same bit has to come and go again.")
        } else if bestPulses < traces.count {
            result.notes.append("It didn't show in every trace (a wipe can fall between two reads): fine if it did in most.")
        }
        if (awayReads[best.id] ?? 0) < 2 {
            result.notes.append("The wipe showed in a single read only: another trace makes it surer.")
        }
        return result
    }
}

// MARK: - Raw export

/// Everything the wiper finder took, as a file to share, so the bits can be worked out by hand if needed.
nonisolated struct WiperExport: Codable {
    struct LeverTake: Codable {
        /// "OFF", "AUTO / INT", …
        let step: String
        /// One space-separated hex string per frame.
        let frames: [String]
    }
    struct MotorSnapshot: Codable {
        /// "Parked (OFF)" / "Wiping (LO)"
        let label: String
        /// DID ("726 DA0B") -> one hex string per read.
        let reads: [String: [String]]
    }
    struct TraceRead: Codable {
        /// Seconds from the start of the trace.
        let t: Double
        let key: String
        let data: String
    }
    let car: String
    let takenAt: String
    let lever: [LeverTake]
    let motor: [MotorSnapshot]
    let traces: [[TraceRead]]
}
