// LightingArbiter.swift
// Decides what the lamp shows when several features want it at the same time.
//
// Every feature (a "source") asks for a scene or withdraws its request; the request with
// the highest priority wins and is sent to the lamp. When a high-priority request is
// withdrawn, the next one takes over automatically, so e.g. closing all doors restores
// whatever Power Mode wants at that moment.
//
// To add a new lighting feature: add a case to `Source` with its priority, then call
// request(_:from:) / clear(_:) from that feature.

import Combine
import Foundation

final class LightingArbiter: ObservableObject {

    /// Higher priority wins. Leave gaps so new features can slot in between.
    enum Source: Int, Comparable, CaseIterable {
        case base = 0                // purple steady: the normal lighting, always there underneath
        case rain = 5                // wipers on (not just the washer): cyan breathing. Above the normal
                                     // purple, below Power Mode
        case powerMode = 10          // red breathing while Power Mode is on (manual shifting, RPM or speed)
        case reverse = 20            // lever in R: yellow breathing. Power Mode's level: R and M never
                                     // meet, and everything above Power Mode is above this too
        case powerTransition = 500   // 3-second red flash while Power Mode switches
        case climateTemp = 600       // A/C set colder / warmer: 3-second blue / red flash
        case turnSignal = 700        // turn signals or hazard lights flashing: current mode colour
        case doorAlert = 1000        // door or boot open: overrides everything

        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .base: return "Normal"
            case .rain: return "Rain mode"
            case .powerMode: return "Power Mode"
            case .reverse: return "Reverse"
            case .powerTransition: return "Power Mode switch"
            case .climateTemp: return "A/C temperature"
            case .turnSignal: return "Turn signal"
            case .doorAlert: return "Door alert"
            }
        }
    }

    struct ActiveScene: Equatable {
        let source: Source
        let scene: LampState
    }

    /// The scene currently shown, and which feature asked for it.
    @Published private(set) var active: ActiveScene?

    /// Called whenever the winning scene changes.
    var onSceneChange: ((LampState) -> Void)?

    private var requests: [Source: LampState] = [:]

    func request(_ scene: LampState, from source: Source) {
        requests[source] = scene
        update()
    }

    func clear(_ source: Source) {
        requests[source] = nil
        update()
    }

    private func update() {
        let winner = requests.max { $0.key < $1.key }.map { ActiveScene(source: $0.key, scene: $0.value) }
        guard winner != active else { return }
        let previousScene = active?.scene
        active = winner
        if let scene = winner?.scene, scene != previousScene {
            onSceneChange?(scene)
        }
    }
}
