// SignalDiff.swift
// Finds a car's on/off signals by comparison, and reads them back. Used for the M flag (MFinder:
// lever in D vs M) and the doors (DoorFinder: each door open vs everything else).
//
// A snapshot is every supported DID read once or twice. Snapshots are grouped into "on" (the thing
// is on: lever in M, this door open) and "off" (it is off: lever in D, this door closed — which
// includes the snapshots where some *other* door is open). The candidates are the bits that keep
// the same value within each group but differ between the two:
//   - values that drift (temperatures) or count aren't steady within a group and drop out;
//   - a bit shared by every door (door-ajar lamp, interior light) is set in some "off" snapshots
//     (other doors open) and drops out too, so what is left is specific to that one door.
// Pure value code (no Bluetooth).

import Foundation

/// An on/off signal found on this car: some bits of one byte of one DID.
nonisolated struct BitSignal: Codable, Equatable {
    /// ECU request header: "7E1" (TCM), "726" (body module), …
    var header: String
    /// DID, 4 hex digits: "1E03".
    var did: String
    /// Byte in the data after "62 <DID>".
    var byteIndex: Int
    /// The bits that differ between off and on.
    var mask: UInt8
    /// byte & mask when off (lever in D, door closed)…
    var valueOff: UInt8
    /// …and when on (lever in M, door open).
    var valueOn: UInt8
    /// Data bytes the DID returns (up to 4 fit one CAN frame).
    var length: Int

    /// true = on, false = off, nil = neither (unexpected value, or the reply was too short / missing).
    func isOn(_ data: [UInt8]?) -> Bool? {
        guard let data, byteIndex < data.count else { return nil }
        let value = data[byteIndex] & mask
        if value == valueOn { return true }
        if value == valueOff { return false }
        return nil
    }

    /// "7E1 221E03 byte 0 mask 10 (D 00 / M 10)" with the given names for off and on.
    func label(off: String, on: String) -> String {
        "\(header) 22\(did) byte \(byteIndex) mask \(Self.hex(mask)) (\(off) \(Self.hex(valueOff)) / \(on) \(Self.hex(valueOn)))"
    }

    private static func hex(_ byte: UInt8) -> String { String(format: "%02X", byte) }
}

nonisolated enum SignalDiff {
    /// Every read of one snapshot, by DID: "7E1 1E03" -> [first read, second read, …].
    typealias Snapshot = [String: [[UInt8]]]

    struct Candidate: Equatable, Identifiable {
        /// "7E1 1E03"
        let key: String
        let byteIndex: Int
        let mask: UInt8
        let valueOff: UInt8
        let valueOn: UInt8
        let length: Int
        /// Higher is likelier: on the preferred ECU, the whole byte steady in each group, a single
        /// bit, a DID with no noisy bytes, only one byte changing.
        let score: Int

        var id: String { "\(key)#\(byteIndex)#\(mask)" }
        var header: String { String(key.prefix { $0 != " " }) }
        var did: String { String(key.drop { $0 != " " }.dropFirst()) }

        var signal: BitSignal {
            BitSignal(header: header, did: did, byteIndex: byteIndex, mask: mask,
                      valueOff: valueOff, valueOn: valueOn, length: length)
        }
    }

    /// Candidates, best first. `ignored` DIDs ("7E1 1E12") are left out.
    static func candidates(on: [Snapshot], off: [Snapshot], ignored: Set<String> = [],
                           preferredHeader: String) -> [Candidate] {
        guard let firstOff = off.first, !on.isEmpty else { return [] }
        // DIDs answered in every snapshot of both groups.
        var keys = Set(firstOff.filter { !$0.value.isEmpty }.keys)
        for snapshot in off + on {
            keys.formIntersection(snapshot.filter { !$0.value.isEmpty }.keys)
        }
        keys.subtract(ignored)

        var result: [Candidate] = []
        for key in keys {
            let offReads = off.flatMap { $0[key] ?? [] }
            let onReads = on.flatMap { $0[key] ?? [] }
            guard let offRef = offReads.first, let onRef = onReads.first,
                  let length = (offReads + onReads).map(\.count).min(), length > 0 else { continue }

            var changed: [(index: Int, mask: UInt8, wholeByteSteady: Bool)] = []
            var quiet = true
            for i in 0..<length {
                let steadyOff = steadyBits(offReads.map { $0[i] })
                let steadyOn = steadyBits(onReads.map { $0[i] })
                let wholeByteSteady = steadyOff == 0xFF && steadyOn == 0xFF
                if !wholeByteSteady { quiet = false }
                let diff = (offRef[i] ^ onRef[i]) & steadyOff & steadyOn
                if diff != 0 { changed.append((i, diff, wholeByteSteady)) }
            }
            for (index, mask, wholeByteSteady) in changed {
                var score = 0
                if key.hasPrefix(preferredHeader + " ") { score += 4 }
                // A clean flag byte reads one value off and another on. A drifting value can line a
                // bit up by chance, but then its whole byte isn't steady.
                if wholeByteSteady { score += 3 }
                switch mask.nonzeroBitCount {
                case 1: score += 2
                case 2: score += 1
                default: break
                }
                if quiet { score += 1 }
                if changed.count == 1 { score += 1 }
                result.append(Candidate(key: key, byteIndex: index, mask: mask,
                                        valueOff: offRef[index] & mask, valueOn: onRef[index] & mask,
                                        length: length, score: score))
            }
        }
        return result.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.byteIndex < $1.byteIndex
        }
    }

    /// True when the best candidate is clearly ahead (alone, or a higher score than the next one).
    /// While two tie, more snapshots are needed: a drifting value can line up with the real bit for a
    /// while, but not for long.
    static func isUnambiguous(_ candidates: [Candidate]) -> Bool {
        guard let first = candidates.first else { return false }
        return candidates.count == 1 || first.score > candidates[1].score
    }

    /// A short text for a scan plan, saved with the scan result so a changed plan scans again.
    static func planSignature(_ plan: [(header: String, ranges: [ClosedRange<Int>])]) -> String {
        plan.map { entry in
            entry.header + ":" + entry.ranges.map { String(format: "%04X-%04X", $0.lowerBound, $0.upperBound) }
                .joined(separator: ",")
        }.joined(separator: ";")
    }

    /// The bits that have the same value in every read (1 = steady).
    static func steadyBits(_ values: [UInt8]) -> UInt8 {
        guard let first = values.first else { return 0 }
        var changing: UInt8 = 0
        for value in values { changing |= value ^ first }
        return ~changing
    }
}

// MARK: - Raw export

/// The raw door snapshots, written to a file so the exact door bits can be worked out by hand when
/// the automatic search is drowned by noise (as the 12V-battery DIDs did on the first tries).
nonisolated struct DoorExport: Codable {
    struct Shot: Codable {
        /// "All closed", "Driver open", …
        let scene: String
        /// DID ("726 DA13") -> one space-separated hex string per read ("00 20", …).
        let reads: [String: [String]]
    }
    let car: String
    let takenAt: String
    let shots: [Shot]
}

nonisolated extension JSONEncoder {
    /// Sorted keys and indentation, so an exported scan is easy to read and diff.
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
