// ShortcutsLauncher.swift
// Runs a shortcut from the Shortcuts app, then opens a URL when it finishes.
//
// Why: iOS gives apps no way to tell QQ Music to play. The Shortcuts app can, through
// QQ Music's own "继续播放" action, so the welcome flow runs a one-step user shortcut
// (AppConfig.Music.shortcutName).
//
// Google Maps is opened through x-callback-url (x-success / x-error / x-cancel), not by a
// step inside the shortcut: if the QQ Music step fails, times out or brings QQ Music to the
// front, a later step in the shortcut would never run and you'd be left in Shortcuts.
// The callback opens Google Maps in every case.

import UIKit

enum ShortcutsLauncher {

    /// shortcuts://x-callback-url/run-shortcut?name=…&x-success=…&x-error=…&x-cancel=…
    static func run(named name: String, thenOpen next: URL) {
        guard let url = url(named: name, thenOpen: next) else { return }
        UIApplication.shared.open(url)
    }

    private static func url(named name: String, thenOpen next: URL) -> URL? {
        guard let name = encode(name), let next = encode(next.absoluteString) else { return nil }
        return URL(string: "shortcuts://x-callback-url/run-shortcut?name=\(name)"
                   + "&x-success=\(next)&x-error=\(next)&x-cancel=\(next)")
    }

    /// Encodes everything except ASCII unreserved characters, so the Google Maps link
    /// (with its own "?", "&" and "=") arrives as one value.
    private nonisolated static func encode(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
