// MazdaTCM.swift
// The transmission module (TCM, request 7E1, reply 7E9) of the Mazda CX-5 2.2D (2015): what its
// values mean. Pure value code (no Bluetooth), used by OBDAdapter.
//
// Measured on this car with the lever in each position:
//
//   lever          P    R    N    D (1st)  M1   M2
//   1E12 (gear)    46   3C   32   01       01   02
//   1E03 byte 0    -    -    -    00       10   10      <- bit 0x10 = lever in M
//
// 1E12 gives P/R/N and the gear, but D1 and M1 read the same there. The M flag (1E03 byte 0,
// bit 0x10) was found by MFinder (D vs M snapshots, SignalDiff) and is built in as
// AppConfig.Transmission.mFlag. The PCM's selector DID 1E23 (Ford-style P/R/N/D/M) isn't answered
// by this car.

import Foundation

enum MazdaTCM {
    /// Request header of the TCM (it answers from 7E9).
    static let header = "7E1"
    /// "Gear" DID: P/R/N codes, or the gear 1…6 in D and M.
    static let gearDID = "1E12"

    /// What 1E12 says on its own, before the M flag is known.
    enum Range: Equatable {
        case park, reverse, neutral
        /// D or M: the gear, nil while between gears (00).
        case forward(Int?)
    }

    static func range(gearCode code: UInt8) -> Range? {
        switch code {
        case 0x46: return .park
        case 0x3C: return .reverse
        case 0x32: return .neutral
        case 0x00: return .forward(nil)
        case 0x01...0x0A: return .forward(Int(code))
        default: return nil
        }
    }

    /// The lever and gear from the TCM gear code and the M flag (true = M, false = D,
    /// nil = no answer). In a forward gear the lever stays nil while the flag is
    /// unknown, because D and M can't be told apart then.
    static func reading(gearCode: UInt8?, manual: Bool?) -> (selector: ELM327.Selector?, gear: Int?) {
        guard let gearCode, let range = range(gearCode: gearCode) else { return (nil, nil) }
        switch range {
        case .park: return (.park, nil)
        case .reverse: return (.reverse, nil)
        case .neutral: return (.neutral, nil)
        case .forward(let gear):
            switch manual {
            case .some(true): return (.manual, gear)
            case .some(false): return (.drive, gear)
            case .none: return (nil, gear)
            }
        }
    }
}
