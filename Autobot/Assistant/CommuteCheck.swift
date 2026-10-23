// CommuteCheck.swift
// Weekday-morning commute for the Welcome. It's a commute to work when
//   - today is a weekday (AppConfig.Commute.weekdays) and it's 7:00-9:59 (AppConfig.Commute.hours),
//   - one saved place is marked Home and one is marked Work, and
//   - the GPS position is within AppConfig.Commute.homeRadius of Home.
// WelcomeAssistant then skips "Where is our destination today?" and goes straight to Work.
//
// Home's address is turned into coordinates by Apple Maps (MKGeocodingRequest). The result is
// cached on the phone per address, and looked up again whenever Home changes, so on a normal
// morning the check needs no network.

import Combine
import CoreLocation
import Foundation
import MapKit

final class CommuteCheck {

    private let places: SavedPlacesStore
    private let currentLocation: @MainActor () -> CLLocation?
    private let geocoder = AddressGeocoder()
    private var subscriptions = Set<AnyCancellable>()

    /// Outcome of the last check, in words (shown on the dashboard).
    private(set) var lastResult = "Not checked yet"

    init(places: SavedPlacesStore, currentLocation: @escaping @MainActor () -> CLLocation?) {
        self.places = places
        self.currentLocation = currentLocation
    }

    /// Looks up Home's coordinates ahead of time, now and whenever Home's address changes.
    func prepare() {
        guard subscriptions.isEmpty else { return }
        places.$places
            .map { places in places.first { $0.role == .home }?.address }
            .removeDuplicates()
            .sink { [weak self] address in
                guard let self, let address else { return }
                let geocoder = self.geocoder
                Task { _ = await geocoder.location(of: address) }
            }
            .store(in: &subscriptions)
    }

    /// The Work place when this drive is the morning commute from Home, otherwise nil.
    /// The reason is written to the speech diagnostic log either way.
    func workDestination(now: Date = Date()) async -> SavedPlace? {
        guard Self.isCommuteTime(now) else {
            return skip("not a weekday between \(AppConfig.Commute.hours.lowerBound):00 "
                        + "and \(AppConfig.Commute.hours.upperBound):00")
        }
        guard let home = places.home, let work = places.work else {
            return skip("Home and/or Work not set in Saved places")
        }
        guard let here = await usableLocation() else {
            return skip("no recent, accurate GPS fix")
        }
        guard let homeLocation = await geocoder.location(of: home.address) else {
            return skip("couldn't find Home's address on the map (\(home.address))")
        }
        let distance = here.distance(from: homeLocation)
        guard distance <= AppConfig.Commute.homeRadius else {
            return skip("\(Int(distance)) m from Home (limit \(Int(AppConfig.Commute.homeRadius)) m)")
        }
        lastResult = "Commute: \(Int(distance)) m from Home -> \(work.name)"
        SpeechDiagnosticLog.write("CommuteCheck: " + lastResult)
        return work
    }

    static func isCommuteTime(_ date: Date) -> Bool {
        let calendar = Calendar.current
        return AppConfig.Commute.weekdays.contains(calendar.component(.weekday, from: date))
            && AppConfig.Commute.hours.contains(calendar.component(.hour, from: date))
    }

    // MARK: Helpers

    private func skip(_ reason: String) -> SavedPlace? {
        lastResult = "No commute: \(reason)"
        SpeechDiagnosticLog.write("CommuteCheck: " + lastResult)
        return nil
    }

    /// The current GPS fix, waiting a little for one if needed (e.g. right after launch).
    private func usableLocation() async -> CLLocation? {
        let deadline = Date().addingTimeInterval(AppConfig.Commute.locationTimeout)
        while true {
            if let location = currentLocation(), Self.isUsable(location) { return location }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private static func isUsable(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= AppConfig.Commute.maxLocationAccuracy
            && -location.timestamp.timeIntervalSinceNow <= AppConfig.Commute.maxLocationAge
    }
}

/// Address text -> coordinates, with a small cache in UserDefaults (address -> [latitude, longitude]).
final class AddressGeocoder {

    private let storageKey = "geocodedAddresses"
    private var cache: [String: [Double]]

    init() {
        cache = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Double]] ?? [:]
    }

    func location(of address: String) async -> CLLocation? {
        let key = Self.key(for: address)
        guard !key.isEmpty else { return nil }
        if let cached = cache[key], cached.count == 2 {
            return CLLocation(latitude: cached[0], longitude: cached[1])
        }
        guard let request = MKGeocodingRequest(addressString: address) else { return nil }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(AppConfig.Commute.geocodeTimeout))
            request.cancel()
        }
        defer { watchdog.cancel() }
        do {
            guard let item = try await request.mapItems.first else { return nil }
            let location = item.location
            cache[key] = [location.coordinate.latitude, location.coordinate.longitude]
            UserDefaults.standard.set(cache, forKey: storageKey)
            return location
        } catch {
            print("Geocoding error:", error)
            return nil
        }
    }

    private static func key(for address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
