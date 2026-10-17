// LampState.swift
// The lighting scenes the lamp can show. Which one is shown is decided by LightingArbiter.

import Foundation

// MARK: - Lamp states

enum LampState: Equatable {
    case purpleSteady    // speed below the Power Mode threshold
    case redBreathing    // speed at or above the threshold (Power Mode)
    case redBurstFlash   // a door or the boot is open (safety alert)

    var label: String {
        switch self {
        case .purpleSteady: return "Purple · steady"
        case .redBreathing: return "Red gradient · breathing"
        case .redBurstFlash: return "Red · burst flash"
        }
    }
}
