// MFinderView.swift
// The dashboard's M finder row and the screen it opens: scan, snapshots in D and M, and the M flag in use
// (MFinder).

import SwiftUI

/// Dashboard row: whether the M flag has been learned; opens the M finder.
struct MFinderButton: View {
    @ObservedObject var finder: MFinder
    @ObservedObject var obd: OBDAdapter
    @ObservedObject var manual: ManualShiftDetector
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack {
                Label("M finder", systemImage: "gearshape.2")
                Spacer()
                Text(finder.learned != nil ? "M flag learned" : "M flag built in")
                    .font(.subheadline)
                    .foregroundColor(.green)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .font(.headline)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            MFinderView(finder: finder, obd: obd, manual: manual)
        }
    }
}

/// Finds the "lever in M" flag on this car (MFinder): scan once, then snapshots in D and in M1.
private struct MFinderView: View {
    @ObservedObject var finder: MFinder
    @ObservedObject var obd: OBDAdapter
    @ObservedObject var manual: ManualShiftDetector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(finder.message)
                    if let progress {
                        ProgressView(value: progress.value) { Text(progress.label).font(.caption) }
                        Button("Cancel", role: .cancel) { finder.cancel() }
                    }
                }
                Section("Live from the car") {
                    LabeledContent("TCM gear code", value: tcmText)
                    LabeledContent("Lever", value: manual.selector?.label ?? "D or M (flag not known)")
                    LabeledContent("Gear", value: manual.gear.map { "\($0)" } ?? "--")
                }
                Section {
                    Button("Scan the car (once, 1–2 min)") { finder.scan() }
                        .disabled(finder.isBusy)
                    LabeledContent("DIDs answering", value: "\(finder.supported.count)")
                    Button("Snapshot D  ·  \(finder.dSnapshots) taken") { finder.snapshotD() }
                        .disabled(finder.isBusy || finder.supported.isEmpty)
                    Button("Snapshot M1  ·  \(finder.mSnapshots) taken") { finder.snapshotM() }
                        .disabled(finder.isBusy || finder.supported.isEmpty)
                    Button("Reset snapshots", role: .destructive) { finder.resetSnapshots() }
                        .disabled(finder.isBusy)
                } header: {
                    Text("Find the M flag")
                } footer: {
                    Text("Car stopped, engine running, foot on the brake. Scan once. Then alternate: "
                         + "lever in D → Snapshot D, lever in M (stay in M1, don't shift) → Snapshot M. "
                         + "After two of each the best candidate is used automatically.")
                }
                if !finder.candidates.isEmpty {
                    Section("Candidates, best first") {
                        ForEach(finder.candidates.prefix(8)) { candidate in
                            Text(candidate.signal.label(off: "D", on: "M") + "  ·  score \(candidate.score)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Section("In use for Power Mode") {
                    Text(finder.inUse.label(off: "D", on: "M") + (finder.learned == nil ? "  ·  built in" : "  ·  learned"))
                        .font(.system(.caption, design: .monospaced))
                    if finder.learned != nil {
                        Button("Forget (back to the built-in flag)", role: .destructive) { finder.forget() }
                            .disabled(finder.isBusy)
                    }
                }
            }
            .navigationTitle("M finder")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var progress: (value: Double, label: String)? {
        switch finder.phase {
        case .idle:
            return nil
        case .scanning(let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "Scanning \(done) / \(total)")
        case .snapshot(let position, let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "Snapshot \(position): \(done) / \(total)")
        }
    }

    private var tcmText: String {
        guard let code = obd.tcmGearCode else {
            return obd.reportsTCMGear == false ? "not answered" : "--"
        }
        let meaning: String
        switch MazdaTCM.range(gearCode: code) {
        case .park?: meaning = "P"
        case .reverse?: meaning = "R"
        case .neutral?: meaning = "N"
        case .forward(let gear)?: meaning = gear.map { "D/M, gear \($0)" } ?? "between gears"
        case nil: meaning = "unknown"
        }
        return code.hex + "  →  " + meaning
    }
}
