// DoorFinderView.swift
// The dashboard's Doors row and the screen it opens: the doors live from the car and the door finder
// (DoorFinder). Hidden while AppConfig.Doors.enabled is off.

import SwiftUI

/// Dashboard row: how many doors are read from the car; opens the doors screen (live values and
/// the finder).
struct DoorFinderButton: View {
    @ObservedObject var finder: DoorFinder
    @ObservedObject var obd: OBDAdapter
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack {
                Label("Doors", systemImage: "car.side")
                Spacer()
                Text(summary)
                    .font(.subheadline)
                    .foregroundColor(obd.doorSignals.isEmpty ? .secondary : .green)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .font(.headline)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            DoorFinderView(finder: finder, obd: obd)
        }
    }

    /// "5 of 5 from the car", or why not.
    private var summary: String {
        let total = DoorMonitor.Opening.allCases.count
        if !obd.doorSignals.isEmpty { return "\(obd.doorSignals.count) of \(total) from the car" }
        return obd.reportsDoors == nil ? "checked on connect" : "0 of \(total) (finder needed)"
    }
}

/// The doors live from the car, where they come from, and the finder (DoorFinder: scan once,
/// "All closed", then one opening at a time) for a door that isn't shown right.
private struct DoorFinderView: View {
    @ObservedObject var finder: DoorFinder
    @ObservedObject var obd: OBDAdapter
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
                Section {
                    ForEach(DoorMonitor.Opening.allCases) { opening in
                        LabeledContent(opening.rawValue, value: liveText(opening))
                    }
                    ForEach(obd.doorRaw.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: obd.doorRaw[key] ?? "")
                            .font(.system(.caption, design: .monospaced))
                    }
                } header: {
                    Text("Live from the car")
                } footer: {
                    Text(sourceText)
                }
                Section {
                    Button("Scan the body control module (once, ~2 min)") { finder.scan() }
                        .disabled(finder.isBusy)
                    LabeledContent("DIDs answering", value: "\(finder.supported.count)")
                    snapshotButton(.allClosed)
                    ForEach(DoorMonitor.Opening.allCases) { opening in
                        snapshotButton(.open(opening))
                    }
                    Button("Reset snapshots", role: .destructive) { finder.resetSnapshots() }
                        .disabled(finder.isBusy)
                } header: {
                    Text("Find the door switches")
                } footer: {
                    Text("Only needed if a door isn't shown right above. Parked, ignition on. Scan once. "
                         + "Then: everything shut → All closed. For each opening: open only that one → its "
                         + "button → close it. Finish with All closed again. A door found this way "
                         + "replaces the built-in one as soon as it's certain.")
                }
                Section("In use") {
                    ForEach(DoorMonitor.Opening.allCases) { opening in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opening.rawValue).font(.subheadline.bold())
                            Text(inUseText(opening))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(obd.doorSignals[opening] == nil ? .secondary : .primary)
                            if finder.learned[opening] == nil, let candidate = finder.best[opening] {
                                Text("finder: maybe " + candidate.signal.label(off: "closed", on: "open")
                                     + " (needs more snapshots)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    if !finder.learned.isEmpty {
                        Button("Forget learned doors", role: .destructive) { finder.forget() }
                            .disabled(finder.isBusy)
                    }
                }
                Section {
                    if let url = finder.exportURL {
                        ShareLink("Export raw scan (send to me)", item: url)
                    } else {
                        Text("Export raw scan — take some snapshots first")
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("If a door can't be found automatically, export the raw scan after one full "
                         + "pass (All closed, each door once, All closed) and share the file, so the "
                         + "exact door bits can be set by hand.")
                }
            }
            .navigationTitle("Doors")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func snapshotButton(_ scene: DoorFinder.Scene) -> some View {
        Button("\(scene.label)  ·  \(finder.counts[scene] ?? 0) taken") { finder.snapshot(scene) }
            .disabled(finder.isBusy || finder.supported.isEmpty)
    }

    private func liveText(_ opening: DoorMonitor.Opening) -> String {
        guard obd.doorSignals[opening] != nil else { return "not known" }
        guard let isOpen = obd.doorStates[opening] else { return "--" }
        return isOpen ? "OPEN" : "closed"
    }

    /// The signal read for this door, and where it comes from.
    private func inUseText(_ opening: DoorMonitor.Opening) -> String {
        guard let signal = obd.doorSignals[opening] else { return "—" }
        return signal.label(off: "closed", on: "open")
            + (finder.learned[opening] == nil ? "  ·  built in" : "  ·  learned")
    }

    /// Where the doors come from, under the live values.
    private var sourceText: String {
        switch obd.reportsDoors {
        case true?:
            return "From the body control module's door status (726 22C150, built in). Open each door "
                + "once to check; the finder below is only needed if one shows wrong."
        case false?:
            return "This car's body control module didn't answer the door status (726 22C150, see the "
                + "log), so doors can only come from the finder below."
        case nil:
            return "Checked when the adapter connects with the ignition on."
        }
    }

    private var progress: (value: Double, label: String)? {
        switch finder.phase {
        case .idle:
            return nil
        case .scanning(let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "Scanning \(done) / \(total)")
        case .snapshot(let label, let done, let total):
            return (total > 0 ? Double(done) / Double(total) : 0, "\(label): \(done) / \(total)")
        }
    }
}
