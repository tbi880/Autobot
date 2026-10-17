// SpeedMonitor.swift
// Reads GPS speed and decides the lamp state:
//   speed <  threshold -> purple steady
//   speed >= threshold -> red gradient breathing
// Also keeps the latest location for the weather briefing.

import Combine
import CoreLocation
import SwiftUI

final class SpeedMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var speedKmh: Double?          // nil until GPS has a valid speed
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var authorization = "Not requested"
    @Published private(set) var state: LampState = .purpleSteady

    /// Called only when the state actually changes (after debouncing).
    var onStateChange: ((LampState) -> Void)?

    private let manager = CLLocationManager()
    private var candidate: LampState?
    private var candidateCount = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        // Keep receiving speed while the phone is locked (needs the "location" background mode)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedAlways: authorization = "Always"
        case .authorizedWhenInUse: authorization = "While using"
        case .denied: authorization = "Denied - enable in Settings"
        case .restricted: authorization = "Restricted"
        default: authorization = "Not determined"
        }
        if m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways {
            m.startUpdatingLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location

        // speed < 0 means invalid; also skip readings with poor speed accuracy
        guard location.speed >= 0,
              location.speedAccuracy >= 0,
              location.speedAccuracy < AppConfig.Speed.maxSpeedAccuracy else { return }

        let kmh = location.speed * 3.6
        speedKmh = kmh
        let target: LampState = kmh >= AppConfig.Speed.powerModeThresholdKmh ? .redBreathing : .purpleSteady
        confirm(target)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        print("Location error:", error.localizedDescription)
    }

    // MARK: Debounce

    /// Switches state only after the same target is seen in several consecutive readings.
    private func confirm(_ target: LampState) {
        guard target != state else {
            candidate = nil
            candidateCount = 0
            return
        }
        if candidate == target {
            candidateCount += 1
        } else {
            candidate = target
            candidateCount = 1
        }
        if candidateCount >= AppConfig.Speed.confirmReadings {
            state = target
            candidate = nil
            candidateCount = 0
            onStateChange?(target)
        }
    }
}
