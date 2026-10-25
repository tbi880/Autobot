// LampState.swift
// The lighting scenes the lamp can show. Which one is shown is decided by LightingArbiter.

import Foundation

// MARK: - Lamp states

enum LampState: Equatable {
    case purpleSteady    // Power Mode off
    case redBreathing    // Power Mode on (manual shifting, RPM or speed: AppConfig.PowerMode.trigger)
    case redBurstFlash   // a door or the boot is open (safety alert)

    var label: String {
        switch self {
        case .purpleSteady: return "Purple · steady"
        case .redBreathing: return "Red gradient · breathing"
        case .redBurstFlash: return "Red · burst flash"
        }
    }
}
