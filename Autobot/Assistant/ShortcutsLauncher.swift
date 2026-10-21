// ShortcutsLauncher.swift
// Runs a shortcut from the Shortcuts app.
// (Which shortcut and what it gets: AppConfig.Music and WelcomeAssistant.startMusicAndOpenMaps.)
//
// Why: iOS gives apps no way to tell QQ Music to play. The Shortcuts app can, through
// QQ Music's own "继续播放" action, so the welcome flow runs a user shortcut
// (AppConfig.Music.shortcutName) with two steps, Google Maps first:
//   1. Open URLs  (Shortcut Input = the Google Maps link we pass in)
//   2. QQ音乐 - 继续播放
// Opening Maps first means a failing or slow QQ Music step can't leave you in Shortcuts.
// Safety net: Shortcuts opens the Google Maps link again when the shortcut finishes
// (x-success), fails (x-error) or is cancelled (x-cancel). So Google Maps always ends up
// in front, even if step 1 got no input or QQ Music pulled itself / Shortcuts to the front.
// (The shortcut can therefore also be just "QQ音乐 - 继续播放".)

import UIKit

enum ShortcutsLauncher {

    /// shortcuts://x-callback-url/run-shortcut?name=…&input=text&text=…&x-success=…&x-error=…&x-cancel=…
    /// - input: text handed to the shortcut as Shortcut Input
    /// - onSuccess: opened by Shortcuts when the shortcut finishes
    /// - onFailure: opened by Shortcuts when it fails or is cancelled
    static func run(named name: String, input: String, onSuccess: URL, onFailure: URL) {
        guard let name = encode(name),
              let text = encode(input),
              let success = encode(onSuccess.absoluteString),
              let failure = encode(onFailure.absoluteString),
              let url = URL(string: "shortcuts://x-callback-url/run-shortcut?name=\(name)"
                            + "&input=text&text=\(text)"
                            + "&x-success=\(success)&x-error=\(failure)&x-cancel=\(failure)")
        else { return }
        UIApplication.shared.open(url)
    }

    /// Encodes everything except ASCII unreserved characters, so the Google Maps link
    /// (with its own "?", "&" and "=") arrives as one value.
    private nonisolated static func encode(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
