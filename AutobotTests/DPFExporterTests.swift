// DPFExporterTests.swift
// The export behind the DPF screen's and the start screen's Export data, without a car or an adapter:
// what goes to the share sheet, what is said when nothing was recorded, and one export at a time.

import Foundation
import Testing
@testable import Autobot

@MainActor @Suite struct DPFExporterTests {

    private let csv = URL(fileURLWithPath: "/tmp/dpf-2026-11.csv")
    private let info = URL(fileURLWithPath: "/tmp/dpf-info.json")
    private let timing = URL(fileURLWithPath: "/tmp/autobot-obd-timing.log")

    /// The recorder's files are shared with the extras (raw scan, timing log) after them.
    @Test func filesAreSharedWithTheExtras() async {
        var asked: [DPFExportRange] = []
        let exporter = DPFExporter(makeFiles: { range in
            asked.append(range)
            return [self.csv, self.info]
        }, extras: { [self.timing] })
        await exporter.export(.month)?.value
        #expect(asked == [.month])
        #expect(exporter.exported?.urls == [csv, info, timing])
        #expect(exporter.note.isEmpty)
        #expect(exporter.exporting == nil)
    }

    /// Nothing recorded in the range: no share sheet (the extras alone aren't sent), and a note that says so.
    @Test func nothingRecordedIsSaid() async {
        let exporter = DPFExporter(makeFiles: { _ in [] }, extras: { [self.timing] })
        await exporter.export(.week)?.value
        #expect(exporter.exported == nil)
        #expect(exporter.note == "Nothing recorded in the last week.")
        await exporter.export(.all)?.value
        #expect(exporter.note == "Nothing to export.")
    }

    /// A second tap while the files are being written starts nothing; the next export clears the old note.
    @Test func oneExportAtATime() async {
        var calls = 0
        let exporter = DPFExporter(makeFiles: { _ in
            calls += 1
            return calls == 1 ? [] : [self.csv]
        })
        let first = exporter.export(.week)
        #expect(exporter.exporting == .week)
        #expect(exporter.export(.year) == nil)
        await first?.value
        #expect(calls == 1)
        #expect(!exporter.note.isEmpty)
        await exporter.export(.year)?.value
        #expect(exporter.note.isEmpty)
        #expect(exporter.exported?.urls == [csv])
    }

    /// Every range the DPF screen offers goes back the right way: each one further than the one before.
    @Test func rangesGoFurtherBack() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let starts = DPFExportRange.allCases.map { $0.start(from: now) }
        #expect(starts.last == .some(nil))                              // Everything
        let dated = starts.compactMap { $0 }
        #expect(dated.count == DPFExportRange.allCases.count - 1)
        #expect(dated == dated.sorted(by: >))
        #expect(dated.allSatisfy { $0 < now })
    }
}
