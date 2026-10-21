// MapsLauncher.swift
// Opens Google Maps in one of three ways (MapsTarget):
//   .none              just open the app
//   .search(text)      search, the driver picks the result
//   .navigate(place)   saved place with an exact address: start turn-by-turn navigation
// Falls back to Google Maps on the web if the app isn't installed.
// Only works while this app is in the foreground (an iOS rule).

import UIKit

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

    static func open(_ target: MapsTarget) {
        if case .navigate(let place) = target {
            // Universal link opens the Google Maps app and starts navigation;
            // if that doesn't open the app, use its own URL scheme (shows the route).
            guard let link = navigationLink(to: place.address) else { return }
            UIApplication.shared.open(link, options: [.universalLinksOnly: true]) { opened in
                guard !opened, let fallback = directionsURL(to: place.address) else { return }
                UIApplication.shared.open(fallback)
            }
            return
        }
        guard let url = url(for: target) else { return }
        UIApplication.shared.open(url)
    }

    /// One URL for the target (used when handing over to the Lamp Drive shortcut).
    /// Navigation uses the app-only form of the link: when Shortcuts opens the plain https
    /// link it ends up in Safari instead of Google Maps.
    static func url(for target: MapsTarget) -> URL? {
        switch target {
        case .none: return searchURL(nil)
        case .search(let text): return searchURL(text)
        case .navigate(let place):
            guard let link = navigationLink(to: place.address) else { return nil }
            return isGoogleMapsInstalled ? appOnly(link) : link
        }
    }

    /// Just brings the Google Maps app to the front, leaving whatever it shows (e.g. the route
    /// the Directions shortcut opened). nil if Google Maps isn't installed.
    static var bringToFrontURL: URL? {
        isGoogleMapsInstalled ? URL(string: "comgooglemaps://") : nil
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

    /// Google Maps URL that starts driving navigation (dir_action=navigate).
    private static func navigationLink(to address: String) -> URL? {
        guard let destination = encode(address) else { return nil }
        return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(destination)"
                   + "&travelmode=driving&dir_action=navigate")
    }

    /// The same Google Maps link, but opened by the Google Maps app itself (never Safari):
    /// https://www.google.com/maps/… → comgooglemapsurl://www.google.com/maps/…
    /// Keeps dir_action=navigate, so navigation still starts straight away.
    private static func appOnly(_ link: URL) -> URL? {
        guard var parts = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "comgooglemapsurl"
        return parts.url
    }

    /// Google Maps app scheme with a driving route to the address.
    private static func directionsURL(to address: String) -> URL? {
        guard let destination = encode(address) else { return nil }
        return URL(string: "comgooglemaps://?daddr=\(destination)&directionsmode=driving")
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
