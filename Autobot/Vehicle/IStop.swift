// IStop.swift
// i-stop (idling stop) auto-off: the value types for reading the car's i-stop state and an
// experimental CAN frame observed while the physical OFF button is held.
//
// Nothing about i-stop is a standard OBD2 PID, so both things are learned on this car by IStopFinder
// (like the M flag and the turn-signal frame):
//
//   - the i-stop STATE: a flag in a PCM UDS value (service 22), found by comparing snapshots with
//     i-stop armed vs disabled — reuses BitSignal (SignalDiff.swift), where "on" means i-stop is
//     currently OFF (disabled, the OFF switch active).
//   - the OFF BUTTON: it is a resistor-ladder switch read by the instrument cluster. FrameDiff finds
//     CAN frames that change when it is held. Replaying one is experimental; rolling counters or
//     checksums can make a captured frame invalid.
//
// Pure value code (no Bluetooth).

import Foundation

/// A CAN frame observed while comparing the OFF button released (`idle`) and held (`pressed`). The
/// 11-bit id and payload are a replay candidate, not proof of a valid synthetic button press.
nonisolated struct FrameSignal: Codable, Equatable {
    /// 11-bit CAN id the frame is broadcast with, e.g. "085".
    var id: String
    /// The frame's data bytes while the OFF button is held.
    var pressed: [UInt8]
    /// …and while nothing is pressed.
    var idle: [UInt8]
    /// idle XOR pressed, per byte: which bytes change when the button is pressed (for the log).
    var mask: [UInt8]

    /// "085 byte 3 00→04" for the bytes that change.
    func label() -> String {
        let changes = (0..<min(mask.count, min(idle.count, pressed.count)))
            .filter { mask[$0] != 0 }
            .map { i in "byte \(i) " + String(format: "%02X→%02X", idle[i], pressed[i]) }
        return id + " " + (changes.isEmpty ? "no change" : changes.joined(separator: ", "))
    }

    /// "2E 85 00 00 04 …": the bytes replayed to press the button.
    var pressedHex: String { pressed.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// Finds frames that differ while the OFF button is held. Same idea as SignalDiff, but over CAN frames
/// (by id) instead of UDS reads. A difference alone does not prove that replaying it is valid.
nonisolated enum FrameDiff {
    /// Every frame heard in one capture window, grouped by id: "085" -> [[bytes], [bytes], …].
    typealias Capture = [String: [[UInt8]]]

    struct Candidate: Equatable, Identifiable {
        /// The CAN id ("085"); also the Identifiable id.
        let id: String
        let pressed: [UInt8]
        let idle: [UInt8]
        let mask: [UInt8]
        /// Higher is likelier: few bytes change, a single bit changes.
        let score: Int

        var frame: FrameSignal { FrameSignal(id: id, pressed: pressed, idle: idle, mask: mask) }
    }

    /// Candidate button frames, best first. An id is a candidate when some byte is steady while the
    /// button is released and steady while it's held, but differs between the two. `ignoredIDs` (the
    /// lights frame, …) are left out; frames that only change by themselves aren't steady and drop out.
    static func candidates(idleCaptures: [Capture], pressedCaptures: [Capture],
                           ignoredIDs: Set<String> = []) -> [Candidate] {
        func merge(_ captures: [Capture]) -> [String: [[UInt8]]] {
            var out: [String: [[UInt8]]] = [:]
            for capture in captures {
                for (id, reads) in capture { out[id, default: []].append(contentsOf: reads) }
            }
            return out
        }
        let idle = merge(idleCaptures)
        let pressed = merge(pressedCaptures)

        var result: [Candidate] = []
        for id in Set(idle.keys).intersection(pressed.keys) {
            if ignoredIDs.contains(id) { continue }
            let idleReads = idle[id] ?? []
            let pressedReads = pressed[id] ?? []
            guard let idleRef = idleReads.first, let pressedRef = pressedReads.first,
                  let length = (idleReads + pressedReads).map(\.count).min(), length > 0 else { continue }

            var mask = [UInt8](repeating: 0, count: length)
            var changedBytes = 0
            for i in 0..<length {
                let steadyIdle = SignalDiff.steadyBits(idleReads.map { $0[i] })
                let steadyPressed = SignalDiff.steadyBits(pressedReads.map { $0[i] })
                let diff = (idleRef[i] ^ pressedRef[i]) & steadyIdle & steadyPressed
                mask[i] = diff
                if diff != 0 { changedBytes += 1 }
            }
            guard changedBytes > 0 else { continue }

            let bits = mask.reduce(0) { $0 + $1.nonzeroBitCount }
            var score = 0
            if changedBytes == 1 { score += 3 }
            switch bits {
            case 1: score += 2
            case 2: score += 1
            default: break
            }
            result.append(Candidate(id: id,
                                    pressed: Array(pressedRef.prefix(length)),
                                    idle: Array(idleRef.prefix(length)),
                                    mask: mask, score: score))
        }
        return result.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }
    }

    /// True when the best candidate is clearly ahead (alone, or a higher score than the next).
    static func isUnambiguous(_ candidates: [Candidate]) -> Bool {
        guard let first = candidates.first else { return false }
        return candidates.count == 1 || first.score > candidates[1].score
    }
}

// MARK: - Bus map and guided sweep (IStopFinder)

/// One look at a block of the bus (OBDAdapter.captureBlock): the frames heard with their CAN ids, and
/// whether the adapter ran out of buffer (too many frames for one look: the block gets split).
nonisolated struct BusLook {
    let frames: [(id: String, data: [UInt8])]
    let overflowed: Bool
}

/// An aligned block of 11-bit CAN ids, base..<base+size (size a power of two), that the bus map found
/// frames in and that fits one look without overflowing the adapter. The sweep takes one per press.
nonisolated struct SweepGroup: Codable, Equatable, Identifiable {
    let base: Int
    let size: Int
    let ids: [String]
    /// Frames a second heard in it while mapping.
    let rate: Double

    var id: Int { base }
    /// "080–0BF · 5 ids"
    var label: String { String(format: "%03X–%03X", base, base + size - 1) + " · \(ids.count) ids" }
}

/// One group of the sweep: its frames with the OFF button released, held and released again, and
/// whether the PCM's i-stop state flipped in between (the press really registered; nil = unknown).
nonisolated struct SweepShot {
    let group: SweepGroup
    let before: FrameDiff.Capture
    let held: FrameDiff.Capture
    let after: FrameDiff.Capture
    let toggled: Bool?
}

/// A frame that changed while the OFF button was held.
nonisolated struct SweepCandidate: Identifiable, Equatable {
    enum Kind: String, Equatable {
        /// Set only while held, back after release: the button itself — what a replay would need.
        case momentary
        /// Changed on the press and stayed: the i-stop status (OFF indicator) echoed on the bus.
        case latched
        /// Neither cleanly (or nothing heard after release).
        case unclear
    }

    let frame: FrameSignal
    let kind: Kind
    let toggled: Bool?
    /// Bytes that change by themselves in this frame (a counter or checksum?): a replay of stale ones
    /// may be rejected by the receiver.
    let volatileBytes: [Int]
    let score: Int

    var id: String { frame.id + "#" + kind.rawValue }

    /// "4F2 byte 2 00→20 · momentary · press registered · byte 7 changes by itself"
    var label: String {
        var parts = [frame.label(), kind.rawValue]
        switch toggled {
        case true?: parts.append("press registered")
        case false?: parts.append("press NOT registered")
        case nil: break
        }
        if !volatileBytes.isEmpty {
            parts.append("byte " + volatileBytes.map(String.init).joined(separator: ",") + " changes by itself")
        }
        return parts.joined(separator: " · ")
    }
}

/// Works out the sweep: per group, the frames released vs held (FrameDiff), each change classified by
/// the frames after release.
nonisolated enum ButtonSweep {
    /// Candidates over all groups, best first: momentary changes from presses that registered first.
    static func analyse(_ shots: [SweepShot]) -> [SweepCandidate] {
        var result: [SweepCandidate] = []
        for shot in shots {
            let held = tail(shot.held)          // the user may have pressed a moment late
            let after = tail(shot.after)        // …or let go a moment late
            for candidate in FrameDiff.candidates(idleCaptures: [shot.before], pressedCaptures: [held]) {
                let kind = classify(candidate, after: after[candidate.id] ?? [])
                var score = candidate.score
                switch kind {
                case .momentary: score += 6
                case .latched: score += 1
                case .unclear: break
                }
                switch shot.toggled {
                case true?: score += 3
                case false?: score -= 4
                case nil: break
                }
                result.append(SweepCandidate(frame: candidate.frame, kind: kind, toggled: shot.toggled,
                                             volatileBytes: volatileBytes(shot.before[candidate.id] ?? []),
                                             score: score))
            }
        }
        return result.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.frame.id < $1.frame.id
        }
    }

    /// The second half of each id's frames (all of them when there are only a few).
    static func tail(_ capture: FrameDiff.Capture) -> FrameDiff.Capture {
        capture.mapValues { frames in frames.count < 4 ? frames : Array(frames.suffix(frames.count / 2)) }
    }

    /// Back to the released value after release = momentary; still the held value = latched.
    static func classify(_ candidate: FrameDiff.Candidate, after: [[UInt8]]) -> SweepCandidate.Kind {
        guard let reference = after.first else { return .unclear }
        var momentary = true
        var latched = true
        for i in 0..<candidate.mask.count where candidate.mask[i] != 0 {
            let column = after.compactMap { i < $0.count ? $0[i] : nil }
            guard i < reference.count, column.count == after.count,
                  SignalDiff.steadyBits(column) & candidate.mask[i] == candidate.mask[i] else { return .unclear }
            let value = reference[i] & candidate.mask[i]
            if value != candidate.idle[i] & candidate.mask[i] { momentary = false }
            if value != candidate.pressed[i] & candidate.mask[i] { latched = false }
        }
        if momentary { return .momentary }
        if latched { return .latched }
        return .unclear
    }

    /// The byte positions that aren't steady across these frames.
    static func volatileBytes(_ frames: [[UInt8]]) -> [Int] {
        guard frames.count > 1, let length = frames.map(\.count).min(), length > 0 else { return [] }
        return (0..<length).filter { i in SignalDiff.steadyBits(frames.map { $0[i] }) != 0xFF }
    }
}

// MARK: - Modules (read-only check)

/// Whether one module answered a tester present through this adapter.
nonisolated struct ModuleCheck: Identifiable, Equatable {
    let header: String
    let name: String
    /// true = answers, false = silent, nil = couldn't be asked.
    let answers: Bool?

    var id: String { header }
}

/// As-built data shown the way FORScan does, to compare with the forum notes. Read-only.
nonisolated enum AsBuilt {
    /// FORScan-style lines for one module's as-built DIDs, assuming DE00 = block 01, DE01 = block 02…:
    /// five data bytes a line, then a checksum = (module high + low byte + block + line + data) AND FF
    /// ("731-01-01 1014 E024 2082": 07+31+01+01+10+14+E0+24+20 = 182 → 82).
    static func lines(module: String, blocks: [String: [UInt8]]) -> [String] {
        guard let moduleValue = Int(module, radix: 16) else { return [] }
        var out: [String] = []
        for did in blocks.keys.sorted() {
            guard let data = blocks[did], let didValue = Int(did, radix: 16), didValue >= 0xDE00 else { continue }
            let block = didValue - 0xDE00 + 1
            var line = 1
            var index = 0
            while index < data.count {
                let chunk = Array(data[index..<min(index + 5, data.count)])
                var sum = (moduleValue >> 8) + (moduleValue & 0xFF) + block + line
                for byte in chunk { sum += Int(byte) }
                let hex = chunk.map { String(format: "%02X", $0) }.joined() + String(format: "%02X", sum & 0xFF)
                let characters = Array(hex)
                let grouped = stride(from: 0, to: characters.count, by: 4)
                    .map { String(characters[$0..<min($0 + 4, characters.count)]) }
                    .joined(separator: " ")
                out.append(String(format: "%03X-%02d-%02d ", moduleValue, block, line) + grouped)
                index += 5
                line += 1
            }
        }
        return out
    }

    /// What 731-01-01 byte B1 bit 4 says (FORScan forum, miatafy: 1 = i-stop on at every start, stock;
    /// 0 = off at every start, the OFF button still turns it on). nil without DE00.
    static func iStopDefault(_ de00: [UInt8]?) -> String? {
        guard let de00, de00.count > 1 else { return nil }
        return de00[1] & 0x10 != 0 ? "on at every start (B1 bit 4 = 1, stock)" : "OFF at every start (B1 bit 4 = 0)"
    }
}
