// ShortcutsLauncher.swift
// Runs a shortcut from the Shortcuts app.
// (Which shortcut and what it gets: AppConfig.Music and WelcomeAssistant.shortcut(for:).)
//
// Why: iOS gives apps no way to tell QQ Music to play. The Shortcuts app can, through
// QQ Music's own actions, so the welcome flow runs a user shortcut that starts QQ Music and
// then opens autobot://maps. (An app can only open other apps while it is in the foreground,
// so the shortcut has to bring Autobot back before Autobot can open Google Maps.)
//
// The plain run-shortcut link is used: since iOS 26.5's security fixes, iOS refuses to open
// the x-callback-url form (x-success / x-error / x-cancel) from another app
// ("LSApplicationWorkspaceErrorDomain Code=115"), so the shortcut never ran.

import UIKit

enum ShortcutsLauncher {

    /// shortcuts://run-shortcut?name=…[&input=text&text=…]
    /// - input: text handed to the shortcut as Shortcut Input (nil = none)
    /// nil if the link couldn't be built.
    static func url(named name: String, input: String? = nil) -> URL? {
        guard let name = encode(name) else { return nil }
        var link = "shortcuts://run-shortcut?name=\(name)"
        if let input {
            guard let text = encode(input) else { return nil }
            link += "&input=text&text=\(text)"
        }
        return URL(string: link)
    }

    /// Whether iOS reports the Shortcuts app as able to open shortcuts:// links
    /// (needs "shortcuts" in LSApplicationQueriesSchemes, which Autobot-Info.plist has).
    static var canOpenShortcuts: Bool {
        guard let url = URL(string: "shortcuts://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Opens the link and reports whether iOS actually opened the Shortcuts app.
    /// (iOS can refuse, e.g. "LSApplicationWorkspaceErrorDomain Code=115", without any other sign.)
    static func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url, options: [:])
    }

    /// Encodes everything except ASCII unreserved characters, so the name and input
    /// arrive as one value each.
    private nonisolated static func encode(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
