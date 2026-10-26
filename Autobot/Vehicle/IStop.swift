// IStop.swift
// i-stop (idling stop) auto-off: the value types for reading the car's i-stop state and for the
// i-stop OFF button the start stop unit broadcasts on the bus.
//
// Nothing about i-stop is a standard OBD2 PID, so both things are learned on this car by IStopFinder
// (like the M flag and the turn-signal frame):
//
//   - the i-stop STATE: a flag in a PCM UDS value (service 22), found by comparing snapshots with
//     i-stop armed vs disabled — reuses BitSignal (SignalDiff.swift), where "on" means i-stop is
//     currently OFF (disabled, the OFF switch active).
//   - the OFF BUTTON: the cluster switch's i-stop OFF button isn't a value to ask for; the start stop
//     unit reads it and puts it on the bus (like the indicators, TurnSignals.swift). To press it from
//     the app that frame is replayed. FrameSignal holds the frame; FrameDiff finds it by comparing
//     the bus with the button released and held.
//
// Pure value code (no Bluetooth).

import Foundation

/// A CAN broadcast frame learned on this car: its 11-bit id and the data bytes with the OFF button
/// released (`idle`) and held (`pressed`). Replaying `pressed` is how the app "presses" the button.
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

/// Finds the OFF-button frame by comparing the whole bus with the button released and held. Same idea
/// as SignalDiff, but over broadcast frames (by CAN id) instead of UDS reads.
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
