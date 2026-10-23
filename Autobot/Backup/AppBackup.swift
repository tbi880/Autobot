// AppBackup.swift
// The backup file format (JSON). Made to grow: every kind of data lives in its own
// optional section under "data", so
//   - a newer app can add sections (e.g. "settings") without breaking old backups, and
//   - an older app simply ignores sections it doesn't know.
// Bump `currentVersion` only for changes that old apps could misread.
//
// {
//   "format": "autobot-backup",
//   "version": 1,
//   "exportedAt": "2026-10-18T09:30:00Z",
//   "app": { "name": "Autobot", "version": "1.0", "build": "1" },
//   "data": {
//     "savedPlaces": [
//       { "id": "6F1C…", "name": "home", "address": "6 Neilon Place, Northcross, Auckland",
//         "role": "home" }                       // optional: "home" / "work"
//     ]
//   }
// }

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct AppBackup: Codable {

    static let formatName = "autobot-backup"
    static let currentVersion = 1

    var format = AppBackup.formatName
    var version = AppBackup.currentVersion
    var exportedAt = Date()
    var app = AppInfo.current
    var data: BackupData

    struct AppInfo: Codable {
        var name: String
        var version: String
        var build: String

        static var current: AppInfo {
            let info = Bundle.main.infoDictionary ?? [:]
            return AppInfo(name: "Autobot",
                           version: info["CFBundleShortVersionString"] as? String ?? "?",
                           build: info["CFBundleVersion"] as? String ?? "?")
        }
    }

    /// One optional section per kind of data. Add new sections here (as optionals).
    struct BackupData: Codable {
        var savedPlaces: [SavedPlace]?
    }

    // MARK: Encoding

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> AppBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: AppBackup
        do {
            backup = try decoder.decode(AppBackup.self, from: data)
        } catch {
            throw BackupError.unreadable
        }
        guard backup.format == formatName else { throw BackupError.notAnAutobotBackup }
        guard backup.version <= currentVersion else { throw BackupError.tooNew(backup.version) }
        return backup
    }

    var suggestedFileName: String {
        let day = exportedAt.formatted(.iso8601.year().month().day())
        return "Autobot-Backup-\(day).json"
    }
}

nonisolated enum BackupError: LocalizedError {
    case unreadable
    case notAnAutobotBackup
    case tooNew(Int)
    case noAccess

    var errorDescription: String? {
        switch self {
        case .unreadable: return "This file isn't a valid backup."
        case .notAnAutobotBackup: return "This JSON file wasn't exported by Autobot."
        case .tooNew(let v): return "This backup (version \(v)) is from a newer Autobot. Update the app first."
        case .noAccess: return "Couldn't open the file."
        }
    }
}

/// Lets ShareLink export a backup as a .json file (Save to Files, AirDrop, WeChat, …).
nonisolated struct BackupFile: Transferable {
    let backup: AppBackup

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(file.backup.suggestedFileName)
            try file.backup.encoded().write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
