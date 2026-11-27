// ShareSheet.swift
// The system share sheet for files written when an export is asked for, and the start screen's export
// (range choice → share sheet) on top of it.

import SwiftUI
import UIKit

/// The system share sheet (AirDrop, Save to Files, WeChat, …) for files written when the export is asked for;
/// ShareLink wants its items up front.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    /// Opens the share sheet when `exporter` has files ready.
    func exportShareSheet(_ exporter: DPFExporter) -> some View {
        modifier(ExportShareSheet(exporter: exporter))
    }

    /// The start screen's export: asks how far back to go, then shares the files; an alert says so when
    /// nothing was recorded in that range.
    func startScreenExport(_ exporter: DPFExporter, isPresented: Binding<Bool>) -> some View {
        modifier(StartScreenExport(exporter: exporter, isPresented: isPresented))
    }
}

private struct ExportShareSheet: ViewModifier {
    @ObservedObject var exporter: DPFExporter

    func body(content: Content) -> some View {
        content.sheet(item: $exporter.exported) { files in
            ShareSheet(items: files.urls)
                .presentationDetents([.medium, .large])
        }
    }
}

private struct StartScreenExport: ViewModifier {
    @ObservedObject var exporter: DPFExporter
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Export recorded data", isPresented: $isPresented, titleVisibility: .visible) {
                ForEach(DPFExportRange.allCases) { range in
                    Button(range.title) { exporter.export(range) }
                }
            } message: {
                Text("How far back? Shares the CSV and a JSON with the drives, events and regeneration log.")
            }
            .alert(exporter.note, isPresented: Binding(get: { !exporter.note.isEmpty },
                                                       set: { if !$0 { exporter.note = "" } })) {
                Button("OK", role: .cancel) {}
            }
            .exportShareSheet(exporter)
    }
}
