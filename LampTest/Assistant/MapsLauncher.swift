// MapsLauncher.swift
// Opens Google Maps, searching for a place if one is given.
// Falls back to Google Maps on the web if the app isn't installed.
// Only works while this app is in the foreground (an iOS rule).

import UIKit

enum MapsLauncher {

    static func open(searching place: String?) {
        guard let url = url(searching: place) else { return }
        UIApplication.shared.open(url)
    }

    static func url(searching place: String?) -> URL? {
        let query = place.flatMap(encode)
        if isGoogleMapsInstalled {
            return URL(string: query.map { "comgooglemaps://?q=\($0)" } ?? "comgooglemaps://")
        }
        return URL(string: query.map { "https://www.google.com/maps/search/?api=1&query=\($0)" }
                   ?? "https://www.google.com/maps")
    }

    /// Needs "comgooglemaps" in LSApplicationQueriesSchemes (LampTest-Info.plist).
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
