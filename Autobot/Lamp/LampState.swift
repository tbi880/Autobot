// LampState.swift
// The lighting scenes the lamp can show. Which one is shown is decided by LightingArbiter.

import Foundation

// MARK: - Lamp states

enum LampState: Equatable {
    case purpleSteady    // Power Mode off
    case redBreathing    // Power Mode on (manual shifting, RPM or speed: AppConfig.PowerMode.trigger)
    case redBurstFlash   // a door or the boot is open (safety alert), Power Mode switching, A/C set warmer
    case blueBurstFlash  // A/C set colder (ClimateTempFlash)
    case yellowBurstFlash // turn signals or hazard lights flashing (TurnSignalFlash)
    case yellowBreathing // lever in R, reversing (ReverseLight)
    case cyanBreathing   // wipers on: rain mode (RainMode)

    var label: String {
        switch self {
        case .purpleSteady: return "Purple · steady"
        case .redBreathing: return "Red gradient · breathing"
        case .redBurstFlash: return "Red · burst flash"
        case .blueBurstFlash: return "Blue · burst flash"
        case .yellowBurstFlash: return "Yellow · burst flash"
        case .yellowBreathing: return "Yellow gradient · breathing"
        case .cyanBreathing: return "Cyan gradient · breathing"
        }
    }
}
