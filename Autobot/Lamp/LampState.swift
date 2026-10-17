// LampState.swift
// The two lighting states the app switches between.

import Foundation

// MARK: - Lamp states

enum LampState: Equatable {
    case purpleSteady    // below the speed threshold
    case redBreathing    // at or above the speed threshold

    var label: String {
        switch self {
        case .purpleSteady: return "Purple · steady"
        case .redBreathing: return "Red gradient · breathing"
        }
    }
}
