// ShortcutsLauncher.swift
// Runs a shortcut from the Shortcuts app.
//
// Why: iOS gives apps no way to tell QQ Music to play. The Shortcuts app can, through
// QQ Music's own "继续播放" action, so the welcome flow runs a user shortcut
// (AppConfig.Music.shortcutName) with two steps, Google Maps first:
//   1. Open URLs  (Shortcut Input = the Google Maps link we pass in)
//   2. QQ音乐 - 继续播放
// Opening Maps first means a failing or slow QQ Music step can't leave you in Shortcuts.
// As a safety net, x-error / x-cancel open the Google Maps link again.

import UIKit

enum ShortcutsLauncher {

    /// shortcuts://x-callback-url/run-shortcut?name=…&input=text&text=…&x-error=…&x-cancel=…
    static func run(named name: String, input: URL) {
        guard let url = url(named: name, input: input) else { return }
        UIApplication.shared.open(url)
    }

    private static func url(named name: String, input: URL) -> URL? {
        guard let name = encode(name), let link = encode(input.absoluteString) else { return nil }
        return URL(string: "shortcuts://x-callback-url/run-shortcut?name=\(name)"
                   + "&input=text&text=\(link)&x-error=\(link)&x-cancel=\(link)")
    }

    /// Encodes everything except ASCII unreserved characters, so the Google Maps link
    /// (with its own "?", "&" and "=") arrives as one value.
    private nonisolated static func encode(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
