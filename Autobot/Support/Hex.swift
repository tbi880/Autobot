// Hex.swift
// Bytes as hex text and back, in one place: OBD2 replies, CAN frames, lamp packets, logs and exports all
// use these.

nonisolated extension UInt8 {
    /// Two upper-case hex digits: 0x0A -> "0A".
    var hex: String {
        let digits = String(self, radix: 16, uppercase: true)
        return self < 0x10 ? "0" + digits : digits
    }
}

nonisolated extension Sequence where Element == UInt8 {
    /// Every byte as two hex digits with `separator` in between: "00 00 20 00".
    func hexString(separator: String = " ") -> String {
        map(\.hex).joined(separator: separator)
    }
}

nonisolated extension Array where Element == UInt8 {
    /// The bytes written as pairs of hex digits at the start of `text`: "620380FF" -> 62 03 80 FF.
    /// Reading stops at the first character that isn't a hex digit; a single digit left over is dropped.
    init(hexPrefix text: some StringProtocol) {
        var bytes: [UInt8] = []
        var high: UInt8?
        for unit in text.utf8 {
            guard let digit = Self.hexDigit(unit) else { break }
            if let first = high {
                bytes.append(first << 4 | digit)
                high = nil
            } else {
                high = digit
            }
        }
        self = bytes
    }

    private static func hexDigit(_ unit: UInt8) -> UInt8? {
        switch unit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return unit - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return unit - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return unit - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
