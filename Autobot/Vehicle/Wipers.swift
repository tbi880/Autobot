// Wipers.swift
// The windshield wiper lever and the washer, read from the lights frame on HS-CAN (0x09A, the same
// frame the turn signals come from, which OBDAdapter listens to every round). Pure value code.
//
// Why that frame: in the CX-5 the start stop unit reads the steering-column switches. The workshop
// manual: it "detects a windshield wiper switch signal" (OFF / AUTO or INT / LO / HI, plus the AUTO
// volume) and the washer switch and sends them to the front body control module "as a CAN signal";
// the FBCM drives the wipers (in AUTO together with the rain sensor, over LIN). The Mazda SkyActiv CAN
// database lists 0x09A as the start stop unit's frame, and openpilot's CX-5 2017+ DBC has WIPER_LO
// (byte 4, 0x02) and WIPER_HI (byte 4, 0x04) in it.
//
// So this is the lever position, not the wiper motor: in AUTO it tells "AUTO", not whether the rain
// sensor is wiping right now (that comes from the front body control module instead, which drives the
// wipers: WiperFinder learns the bit, RainMode reads it while the lever is in AUTO). And the washer has
// its own switch: the lever stays what it is while washing (lever(in:)), the washer shows on its own
// (isWashing), so washing with the lever OFF is "OFF + washer", not wiping.
//
// Which bits are which on this car isn't documented: WiperFinder learns them (a snapshot of the frame
// in each lever position, compared with OFF). Until then the openpilot layout above is the guess
// (AppConfig.Rain.builtIn).

import Foundation

/// Where the wiper lever and the washer are in the lights frame.
nonisolated struct WiperSignal: Codable, Equatable {

    /// A lever position, or the washer.
    nonisolated enum Position: String, Codable, CaseIterable, Identifiable {
        case off, auto, low, high, washer

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "OFF"
            case .auto: return "AUTO / INT"
            case .low: return "LO"
            case .high: return "HI"
            case .washer: return "Washer"
            }
        }
    }

    /// Some bits of one byte of the frame, and the value they have.
    nonisolated struct Term: Codable, Equatable {
        var byte: Int
        var mask: UInt8
        var value: UInt8

        func matches(_ data: [UInt8]) -> Bool {
            byte < data.count && (data[byte] & mask) == value
        }

        /// "byte 4 & 02 = 02"
        var label: String {
            "byte \(byte) & " + String(format: "%02X", mask) + " = " + String(format: "%02X", value)
        }
    }

    /// For each position: the bits where it differs from OFF, with their values in that position.
    /// nil = not known.
    var auto: [Term]?
    var low: [Term]?
    var high: [Term]?
    var washer: [Term]?
    /// All those bits as they are with the lever OFF.
    var off: [Term]

    func terms(for position: Position) -> [Term]? {
        switch position {
        case .off: return off
        case .auto: return auto
        case .low: return low
        case .high: return high
        case .washer: return washer
        }
    }

    /// The lever position this frame shows (HI, LO, AUTO or OFF), whatever the washer does: it has its
    /// own switch and works in every lever position, so pulling it doesn't move the lever. The most
    /// specific position whose bits all match (more bits first; on a tie HI, LO, then AUTO), OFF if
    /// their bits are as with the lever OFF, nil if the frame fits none of them.
    func lever(in data: [UInt8]) -> Position? {
        let known = [Position.high, .low, .auto].compactMap { position -> (position: Position, terms: [Term])? in
            guard let terms = terms(for: position), !terms.isEmpty else { return nil }
            return (position, terms)
        }
        let ranked = known.enumerated().sorted { a, b in
            let bitsA = Self.bitCount(a.element.terms)
            let bitsB = Self.bitCount(b.element.terms)
            return bitsA != bitsB ? bitsA > bitsB : a.offset < b.offset
        }
        for entry in ranked where entry.element.terms.allSatisfy({ $0.matches(data) }) {
            return entry.element.position
        }
        // OFF: the lever's bits as with the lever OFF (the washer's own bits left out).
        var leverBits: [Int: UInt8] = [:]
        for entry in known {
            for term in entry.terms { leverBits[term.byte, default: 0] |= term.mask }
        }
        let isOff = off.allSatisfy { term in
            let mask = term.mask & (leverBits[term.byte] ?? 0)
            return mask == 0 || Term(byte: term.byte, mask: mask, value: term.value & mask).matches(data)
        }
        return isOff ? .off : nil
    }

    /// Whether the washer is in use in this frame (all its bits match), whatever the lever shows.
    func isWashing(_ data: [UInt8]) -> Bool {
        guard let washer, !washer.isEmpty else { return false }
        return washer.allSatisfy { $0.matches(data) }
    }

    /// One line per known position, for the screens: "LO: byte 4 & 02 = 02".
    var descriptions: [String] {
        Position.allCases.compactMap { position -> String? in
            guard let terms = terms(for: position), !terms.isEmpty else { return nil }
            return position.label + ": " + terms.map(\.label).joined(separator: ", ")
        }
    }

    // MARK: Learning

    /// Learns the signal from snapshots taken with the lever in each position (a snapshot: the data of
    /// every frame heard; several snapshots per position are fine). Needs OFF and at least one wiping
    /// position (AUTO, LO or HI). Only bits that keep their value through every snapshot of a position
    /// count, and OFF's through all OFF snapshots (taken at the start and again at the end), so values
    /// that drift or count drop out. `ignored` bits, by byte, never count (the indicator lamps). The
    /// notes say what to look out for.
    static func learn(_ snapshots: [Position: [[[UInt8]]]],
                      ignored: [Int: UInt8]) -> (signal: WiperSignal?, notes: [String]) {
        guard let offSnapshots = snapshots[.off], let offLook = Look(offSnapshots.flatMap { $0 }) else {
            return (nil, ["Take OFF first."])
        }
        var notes: [String] = []
        var signal = WiperSignal(off: [])
        var union = [UInt8](repeating: 0, count: offLook.values.count)
        for position in [Position.auto, .low, .high, .washer] {
            guard let taken = snapshots[position], let look = Look(taken.flatMap { $0 }) else { continue }
            var terms: [Term] = []
            for byte in 0..<min(look.values.count, offLook.values.count) {
                let differ = offLook.steady[byte] & look.steady[byte]
                    & (offLook.values[byte] ^ look.values[byte]) & ~(ignored[byte] ?? 0)
                guard differ != 0 else { continue }
                terms.append(Term(byte: byte, mask: differ, value: look.values[byte] & differ))
                union[byte] |= differ
            }
            if terms.isEmpty {
                notes.append("\(position.label): no bit of this frame differs from OFF.")
            }
            signal.set(terms.isEmpty ? nil : terms, for: position)
        }
        signal.off = union.enumerated().compactMap { byte, mask -> Term? in
            mask == 0 ? nil : Term(byte: byte, mask: mask, value: offLook.values[byte] & mask)
        }
        guard [signal.auto, signal.low, signal.high].contains(where: { $0 != nil }) else {
            return (nil, notes + ["No wiper bit found yet: take LO or HI."])
        }
        if offSnapshots.count < 2 {
            notes.append("Take OFF once more at the end, so values that drift by themselves drop out.")
        }
        if let washer = signal.washer {
            for position in [Position.auto, .low, .high] where signal.terms(for: position) == washer {
                notes.append("The washer reads the same as \(position.label): rain mode can't tell them apart.")
            }
        } else if snapshots[.washer] == nil {
            notes.append("Take Washer too, so the washer's wipes in AUTO aren't taken for rain.")
        }
        return (signal, notes)
    }

    // MARK: Helpers

    private mutating func set(_ terms: [Term]?, for position: Position) {
        switch position {
        case .off: off = terms ?? []
        case .auto: auto = terms
        case .low: low = terms
        case .high: high = terms
        case .washer: washer = terms
        }
    }

    private static func bitCount(_ terms: [Term]) -> Int {
        terms.reduce(0) { $0 + $1.mask.nonzeroBitCount }
    }

    /// What a set of frames has in common: the first frame's bytes, and per byte the bits that never
    /// change (over the length all frames have).
    private nonisolated struct Look {
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
            self.steady = changing.map { ~$0 }
        }
    }
}
