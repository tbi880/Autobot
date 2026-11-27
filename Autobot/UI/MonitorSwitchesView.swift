// MonitorSwitchesView.swift
// The switches for what is monitored (MonitorSwitches), opened from the DPF screen's data recorder card:
// one per group of values and, inside each group, one per value. Off = not read from the car and not
// recorded. Also shows the pace the recorder keeps, which follows what is switched on.

import SwiftUI

struct MonitorSwitchesView: View {
    @ObservedObject var switches: MonitorSwitches
    @ObservedObject var recorder: DPFRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                paceSection
                ForEach(MonitorGroup.allCases) { group in
                    groupSection(group)
                }
                Section {
                    Toggle("PCM DID sweep", isOn: Binding(
                        get: { !switches.selection.sweepOff },
                        set: { switches.selection.sweepOff = !$0 }))
                } footer: {
                    Text("A few of the PCM's other DIDs with every 30 s sample, raw only, to find what else it answers.")
                }
                Section {
                    Button("Switch everything on") { switches.reset() }
                        .disabled(switches.selection == MonitorSelection())
                }
            }
            .navigationTitle("Monitored values")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Pace

    private var paceSection: some View {
        Section {
            LabeledContent("Values switched on", value: "\(onCount) of \(DPFRecordPlan.fields.count)")
            if let pace = recorder.pace {
                LabeledContent("A sample", value: String(format: "every %.0f s", pace.fast))
                LabeledContent("Slower values", value: String(format: "every %.0f s / %.0f s", pace.normal, pace.slow))
                LabeledContent("Link needed at the usual pace", value: String(format: "%.0f %%", pace.demand * 100))
            }
            if let seconds = recorder.secondsPerRead {
                LabeledContent("One read takes", value: String(format: "%.0f ms", seconds * 1000))
            }
            if recorder.regenOverride {
                Label("Regeneration: values that are switched off are recorded too, until it's over.",
                      systemImage: "flame")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Pace")
        } footer: {
            Text(paceFooter)
        }
    }

    private var paceFooter: String {
        String(format: """
            The adapter answers one request at a time, and the turn signals, the selector and the road speed \
            share it. The recorder measures how long its reads take and uses at most %.0f %% of the link: with \
            many values on, samples come less often; with few, more often (never under %.0f s). Switched off = \
            not read and not recorded. During a regeneration everything that has to do with it is recorded \
            whatever is set here; the regeneration requests and count are always read, to notice one.
            """, AppConfig.DPF.recordLinkShare * 100, AppConfig.DPF.recordMinInterval)
    }

    private var onCount: Int {
        DPFRecordPlan.fields.filter { switches.selection.monitors(did: $0.did) }.count
    }

    // MARK: Groups

    private func groupSection(_ group: MonitorGroup) -> some View {
        let fields = DPFRecordPlan.fields.filter { $0.group == group }
        let groupOn = switches.selection.isOn(group)
        let on = groupOn ? fields.filter { switches.selection.isOn(did: $0.did) }.count : 0
        return Section {
            Toggle(isOn: Binding(
                get: { switches.selection.isOn(group) },
                set: { switches.selection.set(group, on: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                    Text("\(on) of \(fields.count) on" + (group.regenRelated ? " · always on during a regeneration" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Each value") {
                ForEach(fields, id: \.did) { field in
                    Toggle(isOn: Binding(
                        get: { switches.selection.isOn(did: field.did) },
                        set: { switches.selection.set(did: field.did, on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.title)
                                .font(.callout)
                            Text(caption(field))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!groupOn)
                }
            }
        }
    }

    private func caption(_ field: DPFRecordField) -> String {
        var parts = [field.header + " 22" + field.did, field.tier.title]
        if !field.columns.isEmpty { parts.append(field.columns.joined(separator: ", ")) } else { parts.append("raw only") }
        if MonitorGroup.sentinelDIDs.contains(field.did) { parts.append("always read to notice a regeneration") }
        return parts.joined(separator: " · ")
    }
}

extension DPFRecordField.Tier {
    /// "every sample", "every 30 s"…: the interval it starts from (the pace can stretch it).
    nonisolated var title: String {
        switch self {
        case .fast: return "every sample"
        case .normal: return "every 30 s"
        case .slow: return "every 2 min"
        case .once: return "once a drive"
        }
    }
}
