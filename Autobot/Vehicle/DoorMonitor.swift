// DoorMonitor.swift
// Which doors / the boot are open.
// For now it is driven by the test buttons; later the OBD2 (ECU) connection will call
// setOpen(_:_:) with real data, and nothing else needs to change.

import Combine
import Foundation

final class DoorMonitor: ObservableObject {

    enum Opening: String, CaseIterable, Identifiable {
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
