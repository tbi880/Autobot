// BackupManager.swift
// Builds a backup from the app's data, and restores one.
// When a new kind of data is added: fill its section in makeBackup() and apply it in restore().

import Foundation

final class BackupManager {

    enum RestoreMode {
        /// Same-name places get the backup's address; new ones are added; nothing is removed.
        case merge
        /// Everything is replaced by what's in the backup.
        case replace
    }

    private let places: SavedPlacesStore

    init(places: SavedPlacesStore) {
        self.places = places
    }

    func makeBackup() -> AppBackup {
        AppBackup(data: .init(savedPlaces: places.places))
    }

    /// Reads a file picked with the Files picker (security-scoped URL).
    func readBackup(at url: URL) throws -> AppBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw BackupError.noAccess }
        return try AppBackup.decode(data)
    }

    /// Applies the backup and returns a one-line summary for the user.
    func restore(_ backup: AppBackup, mode: RestoreMode) -> String {
        var summary: [String] = []
        if let saved = backup.data.savedPlaces {
            switch mode {
            case .replace:
                places.replaceAll(with: saved)
                summary.append("\(saved.count) saved places restored")
            case .merge:
                let result = places.merge(saved)
                summary.append("\(result.added) places added, \(result.updated) updated")
            }
        }
        return summary.isEmpty ? "Nothing to restore in this backup." : summary.joined(separator: "\n")
    }
}
