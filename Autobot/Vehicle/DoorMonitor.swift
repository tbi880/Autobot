// DoorMonitor.swift
// Which doors / the boot are open.
// Driven by the car while OBDAdapter reads the doors (the BCM's door status 726 22C150, or doors
// DoorFinder learned; AppModel calls setOpen(_:_:)), otherwise by the test buttons.

import Combine
import Foundation

final class DoorMonitor: ObservableObject {

    /// Nonisolated, so the built-in door table in AppConfig (nonisolated) can be keyed by it.
    nonisolated enum Opening: String, CaseIterable, Identifiable {
        case frontLeft = "Driver"
        case frontRight = "Passenger"
        case rearLeft = "Rear L"
        case rearRight = "Rear R"
        case boot = "Boot"

        var id: String { rawValue }
    }

    @Published private(set) var open: Set<Opening> = []

    var isAnyOpen: Bool { !open.isEmpty }

    func setOpen(_ opening: Opening, _ isOpen: Bool) {
        if isOpen { open.insert(opening) } else { open.remove(opening) }
    }

    /// Test button helper.
    func toggle(_ opening: Opening) {
        setOpen(opening, !open.contains(opening))
    }
}
