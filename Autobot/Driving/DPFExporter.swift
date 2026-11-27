// DPFExporter.swift
// One "Export data" control: the DPF screen's recorder card and the start screen's button each have one,
// so the same export works with or without ENGINE START (the recorded files are on the phone; nothing is
// asked of the car).
//
//   export(range) ──▶ DPFRecorder.makeExport (the CSV rows since then + the JSON info)
//                     + DPFHistoryFinder's raw scan + the OBD link's timing log, when there are any
//     ──▶ `exported` (the share sheet's files), or `note` when there was nothing in the range

import Combine
import Foundation

/// An export ready to share.
nonisolated struct ExportedFiles: Identifiable, Sendable {
    let id = UUID()
    let urls: [URL]
}

final class DPFExporter: ObservableObject {

    /// The range being prepared; nil when idle.
    @Published private(set) var exporting: DPFExportRange?
    /// What's ready for the share sheet.
    @Published var exported: ExportedFiles?
    /// Why there was nothing to share ("" when there was).
    @Published var note = ""

    private let makeFiles: @MainActor (DPFExportRange) async -> [URL]
    private let extras: @MainActor () -> [URL]

    /// `makeFiles` writes the recorder's files for a range (empty: nothing recorded in it); `extras` are
    /// sent along when there is something to send.
    init(makeFiles: @escaping @MainActor (DPFExportRange) async -> [URL],
         extras: @escaping @MainActor () -> [URL] = { [] }) {
        self.makeFiles = makeFiles
        self.extras = extras
    }

    convenience init(recorder: DPFRecorder, finder: DPFHistoryFinder) {
        self.init(makeFiles: { [weak recorder] range in await recorder?.makeExport(range) ?? [] },
                  extras: { [weak finder] in [finder?.exportURL, OBDTimingLog.exportURL].compactMap { $0 } })
    }

    /// Has the files written for `range`, then hands them to the share sheet. Ignored while another export
    /// is being prepared. The task is returned so a test can wait for it.
    @discardableResult
    func export(_ range: DPFExportRange) -> Task<Void, Never>? {
        guard exporting == nil else { return nil }
        exporting = range
        note = ""
        return Task {
            let files = await makeFiles(range)
            exporting = nil
            if files.isEmpty {
                note = Self.emptyNote(for: range)
            } else {
                exported = ExportedFiles(urls: files + extras())
            }
        }
    }

    static func emptyNote(for range: DPFExportRange) -> String {
        range == .all ? "Nothing to export." : "Nothing recorded in the \(range.title.lowercased())."
    }
}
