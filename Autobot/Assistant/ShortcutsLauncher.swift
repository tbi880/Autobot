// ShortcutsLauncher.swift
// Runs a shortcut from the Shortcuts app.
//
// Why: iOS gives apps no way to tell QQ Music to play. The Shortcuts app can,
// through QQ Music's own "继续播放" action. So the welcome flow hands over to a
// small user-made shortcut (AppConfig.Music.shortcutName) that
//   1. runs QQ Music "继续播放" (resume the last song), then
//   2. opens the Google Maps link passed in as the shortcut's input.

import UIKit

enum ShortcutsLauncher {

    /// Opens shortcuts://run-shortcut?name=…&input=text&text=…
    static func run(named name: String, input: String) {
        guard let url = url(named: name, input: input) else { return }
        UIApplication.shared.open(url)
    }

    private static func url(named name: String, input: String) -> URL? {
        guard let name = encode(name), let input = encode(input) else { return nil }
        return URL(string: "shortcuts://run-shortcut?name=\(name)&input=text&text=\(input)")
    }

    /// Encodes everything except ASCII unreserved characters, so the Google Maps link
    /// (with its own "?", "&" and "=") arrives as one value.
    private nonisolated static func encode(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
