// MapsLauncher.swift
// Opens Google Maps in one of three ways (MapsTarget):
//   .none              just open the app
//   .search(text)      search, the driver picks the result
//   .navigate(place)   saved place with an exact address: start turn-by-turn navigation
//                      (universal Maps URL with dir_action=navigate)
// HTTPS navigation URLs open Google Maps when installed, or the web version otherwise.
// Only works while this app is in the foreground (an iOS rule).

import UIKit

enum MapsNavigationMode: String, CaseIterable, Identifiable {
    case https
    case appScheme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .https: return "HTTPS"
        case .appScheme: return "App scheme"
        }
    }
}

enum MapsTarget: Equatable {
    case none
    case search(String)
    case navigate(SavedPlace)

    /// What the assistant should say after Google Maps opens (nil = nothing).
    var announcement: String? {
        switch self {
        case .none: return nil
        case .search: return AppConfig.Phrases.foundPlaces
        case .navigate(let place): return AppConfig.Phrases.navigating(to: place.name)
        }
    }

    var summary: String {
        switch self {
        case .none: return "opened Google Maps"
        case .search(let text): return "searched \"\(text)\""
        case .navigate(let place): return "navigating to \(place.name)"
        }
    }
}

enum MapsLauncher {
    static let navigationModeStorageKey = "maps.navigationMode"

    /// Opens Google Maps. Only works while Autobot is in the foreground.
    static func open(_ target: MapsTarget) {
        guard let url = url(for: target) else { return }
        UIApplication.shared.open(url)
    }

    /// Opens Google Maps and reports whether iOS actually opened it.
    static func openReportingResult(_ target: MapsTarget) async -> Bool {
        guard let url = url(for: target) else { return false }
        return await UIApplication.shared.open(url, options: [:])
    }

    static func url(for target: MapsTarget) -> URL? {
        switch target {
        case .none: return searchURL(nil)
        case .search(let text): return searchURL(text)
        case .navigate(let place):
            switch navigationMode {
            case .https:
                return universalNavigationURL(to: place.address)
            case .appScheme:
                return isGoogleMapsInstalled ? appNavigationURL(to: place.address)
                                             : universalNavigationURL(to: place.address)
            }
        }
    }

    private static var navigationMode: MapsNavigationMode {
        let storedValue = UserDefaults.standard.string(forKey: navigationModeStorageKey)
        return storedValue.flatMap(MapsNavigationMode.init(rawValue:)) ?? .https
    }

    // MARK: URLs

    private static func searchURL(_ text: String?) -> URL? {
        let query = text.flatMap(encode)
        if isGoogleMapsInstalled {
            return URL(string: query.map { "comgooglemaps://?q=\($0)" } ?? "comgooglemaps://")
        }
        return URL(string: query.map { "https://www.google.com/maps/search/?api=1&query=\($0)" }
                   ?? "https://www.google.com/maps")
    }

    /// Universal Maps URL: iOS hands this to Google Maps when installed; otherwise it opens
    /// in the browser. `dir_action=navigate` asks Google Maps to start turn-by-turn navigation
    /// when the current device location is available.
    private static func universalNavigationURL(to address: String) -> URL? {
        guard let destination = encode(address) else { return nil }
        return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(destination)"
                   + "&travelmode=driving&dir_action=navigate")
    }

    /// iOS-specific Google Maps scheme. This requests driving directions from the current location.
    private static func appNavigationURL(to address: String) -> URL? {
        guard let destination = encode(address) else { return nil }
        return URL(string: "comgooglemaps://?saddr=&daddr=\(destination)&directionsmode=driving")
    }

    /// Needs "comgooglemaps" in LSApplicationQueriesSchemes (Autobot-Info.plist).
    private static var isGoogleMapsInstalled: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Percent-encodes everything except ASCII unreserved characters (so "&", "+", "#" and Chinese are safe).
    private nonisolated static func encode(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
