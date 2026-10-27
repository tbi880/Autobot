// LampState.swift
// The lighting scenes the lamp can show. Which one is shown is decided by LightingArbiter.

import Foundation

// MARK: - Lamp states

enum LampState: Equatable {
    case purpleSteady    // Power Mode off
    case redBreathing    // Power Mode on (manual shifting, RPM or speed: AppConfig.PowerMode.trigger)
    case redBurstFlash   // Power Mode turn signals/switching, a door alert, or A/C set warmer
    case blueBurstFlash  // A/C set colder (ClimateTempFlash)
    case purpleBurstFlash // turn signals or hazard lights flashing in normal driving mode
    case yellowBreathing // lever in R, reversing (ReverseLight)
    case cyanBreathing   // wipers on: rain mode (RainMode)

    var label: String {
        switch self {
        case .purpleSteady: return "Purple · steady"
        case .redBreathing: return "Red gradient · breathing"
        case .redBurstFlash: return "Red · burst flash"
        case .blueBurstFlash: return "Blue · burst flash"
        case .purpleBurstFlash: return "Purple · burst flash"
        case .yellowBreathing: return "Yellow gradient · breathing"
        case .cyanBreathing: return "Cyan gradient · breathing"
        }
    }
}
