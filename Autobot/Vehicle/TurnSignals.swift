// TurnSignals.swift
// The turn signals and the hazard lights, heard on the car's HS-CAN bus: which frame and bits carry
// the indicator lamps, and when they count as flashing. Pure value code (no Bluetooth): OBDAdapter
// listens to the bus for a moment every round (ELM327 "ATMA") and hands what it heard to
// TurnSignalDetector; TurnSignalFlash turns the result into the yellow flash.
//
// The frame: 0x09A ("lights"), broadcast about 10 times a second on HS-CAN (OBD pins 6/14, the bus the
// KW905 connects to). Byte 2 has the indicator lamps, following the flasher: lit, dark, lit… about
// 0.35 s each. Two community databases put them on different bits, so all four are watched:
//
//   byte 2      0x20    0x10    0x08        0x04
//   SkyActiv    left    right   lights on   -       Mazda SkyActiv CAN database (majbthrd/MazdaCANbus,
//                                                   first-generation SkyActiv, the 2015 CX-5's family;
//                                                   0x20 / 0x10 also light an ND MX-5 cluster's arrows)
//   openpilot   -       -       right       left    mazda_2017.dbc (CX-5 2017+, Mazda3 / Mazda6 2017)
//
// Only a bit that flashes counts. A steady bit (the lights-on bit of the first layout) never does: lit
// without a break for a whole `steadyWindow`, it is marked steady and ignored until it goes dark.
//
// When it counts as flashing (TurnSignalDetector; timings in AppConfig.TurnSignals):
//   - while off: a lit phase that ended (lit → dark) starts it. A look lasts at least one dark phase
//     (`idleListen`), so a flashing indicator is never missed. The rising edge of a bit already seen
//     flashing (since the app started) starts it at once.
//   - while flashing: any edge (dark → lit or lit → dark) keeps it going; dark for a whole `offWindow`
//     ends it, and so does nothing conclusive for `holdLimit` (frames missing).
//   - both sides flashing: the hazard lights.

import Foundation

private typealias Config = AppConfig.TurnSignals

nonisolated enum TurnSignals {

    /// What the indicators are doing.
    nonisolated enum State: Equatable {
        case off, left, right, hazard

        var isOn: Bool { self != .off }

        var label: String {
            switch self {
            case .off: return "Off"
            case .left: return "Left"
            case .right: return "Right"
            case .hazard: return "Hazard"
            }
        }
    }

    /// "00 00 20 00 00 00 00 00"
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// Follows the indicator lamp bits through OBDAdapter's listening windows ("looks"). While listening
/// it is asked whether to listen on (keepListening); at the end of each look it's told what was heard
/// (finish), which updates `state`.
nonisolated struct TurnSignalDetector {

    /// Where the lamp bits are and how long things take (AppConfig.TurnSignals).
    nonisolated struct Tuning {
        var byteIndex = Config.lampByte
        var leftBits = Config.leftBits
        var rightBits = Config.rightBits
        var idleListen = Config.idleListen
        var offWindow = Config.offWindow
        var steadyWindow = Config.steadyWindow
        var firstFrameTimeout = Config.firstFrameTimeout
        var maxListen = Config.maxListen
        var holdLimit = Config.holdLimit

        /// Every bit that may be an indicator.
        var lampBits: UInt8 { leftBits | rightBits }
    }

    let tuning: Tuning
    /// What the indicators do now.
    private(set) var state: TurnSignals.State = .off
    /// Bits lit without a break for a whole steadyWindow: steady lights (lights on), not indicators.
    /// Ignored until they're seen dark.
    private(set) var steadyBits: UInt8 = 0
    /// Bits seen flashing (a lit phase that ended) since the app started: their next rising edge starts
    /// the flash at once. A bit that later stays lit for a whole steadyWindow is dropped again.
    private(set) var indicatorBits: UInt8 = 0
    private var lastFlash: Date?

    /// A look whose frames stopped coming this long before its end proves nothing about "dark".
    private static let freshLimit: TimeInterval = 0.35

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Asked while listening, after every frame and every 50 ms: listen on (true), or is this look
    /// decided (false)? `started`: when the look began.
    func keepListening(_ frames: [CANFrame], started: Date, now: Date) -> Bool {
        if now.timeIntervalSince(started) >= tuning.maxListen { return false }
        let lamp = lampValues(frames)
        guard let first = lamp.first else {
            return now.timeIntervalSince(started) < tuning.firstFrameTimeout       // nothing heard yet
        }
        let look = Look(lamp, watched: watchedBits, all: tuning.lampBits)
        if flashing(in: look) != 0 { return false }                                 // decided: flashing
        let heard = now.timeIntervalSince(first.time)
        if look.litNow != 0 { return heard < tuning.steadyWindow }                  // lit: wait for it to go dark
        return heard < (state.isOn ? tuning.offWindow : tuning.idleListen)          // dark: wait for a flash
    }

    /// The look is over (`ended`: when it was decided): updates the state from what was heard.
    @discardableResult
    mutating func finish(_ frames: [CANFrame], ended: Date) -> TurnSignals.State {
        let lamp = lampValues(frames)
        guard let first = lamp.first, let last = lamp.last else {
            expire(at: ended)                                   // nothing heard: no news
            return state
        }
        let look = Look(lamp, watched: watchedBits, all: tuning.lampBits)
        let heard = ended.timeIntervalSince(first.time)
        let fresh = ended.timeIntervalSince(last.time) < Self.freshLimit
        // Lit through a whole steadyWindow: a steady light. Seen dark: not steady (any more).
        let newSteady: UInt8 = (heard >= tuning.steadyWindow && fresh) ? look.litEvery : 0
        steadyBits = (steadyBits & ~look.everDark) | newSteady
        indicatorBits &= ~newSteady
        let flashes = flashing(in: look) & ~newSteady
        if flashes != 0 {
            indicatorBits |= look.fell & ~newSteady
            state = side(of: flashes)
            lastFlash = ended
        } else if state.isOn, (look.litAny & ~newSteady) == 0, fresh, heard >= tuning.offWindow {
            state = .off                                        // dark for a whole off-window: stopped
            lastFlash = nil
        }
        expire(at: ended)
        return state
    }

    /// Live data stopped: nothing is known any more. (The bits seen flashing are kept.)
    mutating func reset() {
        state = .off
        steadyBits = 0
        lastFlash = nil
    }

    // MARK: Helpers

    /// The bits that may be indicators now: the lamp bits that aren't a steady light.
    private var watchedBits: UInt8 { tuning.lampBits & ~steadyBits }

    /// The edges that say "flashing": while off, a lit phase that ended (or the rising edge of a bit
    /// already seen flashing); while flashing, any edge.
    private func flashing(in look: Look) -> UInt8 {
        state.isOn ? (look.rose | look.fell) : (look.fell | (look.rose & indicatorBits))
    }

    private func side(of bits: UInt8) -> TurnSignals.State {
        let left = (bits & tuning.leftBits) != 0
        let right = (bits & tuning.rightBits) != 0
        if left && right { return .hazard }
        return left ? .left : .right
    }

    /// The lamp byte of every frame long enough to have it, in order.
    private func lampValues(_ frames: [CANFrame]) -> [(time: Date, value: UInt8)] {
        let index = tuning.byteIndex
        return frames.compactMap { frame -> (time: Date, value: UInt8)? in
            frame.data.count > index ? (time: frame.time, value: frame.data[index]) : nil
        }
    }

    /// No flash heard for holdLimit (nothing conclusive came in): off.
    private mutating func expire(at now: Date) {
        guard state.isOn, let lastFlash, now.timeIntervalSince(lastFlash) > tuning.holdLimit else { return }
        state = .off
        self.lastFlash = nil
    }

    /// What the lamp bits did during one look, frame by frame.
    private nonisolated struct Look {
        /// Lit in every frame / in some frame / in the latest one (watched bits only).
        var litEvery: UInt8 = 0xFF
        var litAny: UInt8 = 0
        var litNow: UInt8 = 0
        /// Dark → lit and lit → dark from one frame to the next (watched bits only).
        var rose: UInt8 = 0
        var fell: UInt8 = 0
        /// Dark in some frame (all lamp bits, the steady ones too).
        var everDark: UInt8 = 0

        init(_ values: [(time: Date, value: UInt8)], watched: UInt8, all: UInt8) {
            var previous: UInt8?
            for (_, value) in values {
                litEvery &= value
                litAny |= value
                everDark |= ~value
                if let previous {
                    rose |= value & ~previous
                    fell |= previous & ~value
                }
                previous = value
            }
            litEvery &= watched
            litAny &= watched
            litNow = (previous ?? 0) & watched
            rose &= watched
            fell &= watched
            everDark &= all
        }
    }
}
