// EngineHealthView.swift
// The engine health watch (EngineHealth) on the DPF screen: every value tied to fuel getting into the oil,
// with its level, what it reads, its normal range and — tapped, or while it isn't normal — what it means
// and what to check. Plus the dashboard badge when something isn't normal.

import SwiftUI

/// The list inside the DPF screen's "Engine health" card.
struct EngineHealthList: View {
    @ObservedObject var health: EngineHealth
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(Self.color(health.worst))
            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(health.items.filter { $0.group == group }) { item in
                        row(item)
                    }
                }
                .padding(.top, 4)
            }
            Text("Ranges: Mazda's SKYACTIV-D 2.2 workshop manual where it gives one, otherwise Autobot's own guide "
                 + "(AppConfig.EngineHealth). The values come from the DPF recorder's samples, so they fill in while "
                 + "live data runs. Tap a row for what it means.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let concerns = health.concerns
        if concerns.isEmpty {
            return health.items.allSatisfy { $0.level == .unknown }
                ? "No data yet: it fills in while live data runs (engine on, adapter connected)."
                : "Nothing out of range."
        }
        let high = concerns.filter { $0.level == .high }.count
        let watch = concerns.count - high
        var parts: [String] = []
        if high > 0 { parts.append("\(high) to check soon") }
        if watch > 0 { parts.append("\(watch) to watch") }
        return parts.joined(separator: ", ") + ": " + concerns.map(\.title).joined(separator: "; ")
    }

    /// The groups in the order the items come in.
    private var groups: [String] {
        var seen: [String] = []
        for item in health.items where !seen.contains(item.group) { seen.append(item.group) }
        return seen
    }

    private func row(_ item: EngineHealth.Item) -> some View {
        let off = item.level >= .watch
        let open = off || expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Self.color(item.level))
                    .frame(width: 9, height: 9)
                Text(item.title).font(.subheadline)
                Spacer(minLength: 8)
                Text(Self.name(item.level))
                    .font(.caption)
                    .foregroundStyle(Self.color(item.level))
            }
            Group {
                Text(item.value)
                    .font(.subheadline)
                    .monospacedDigit()
                Text(item.range)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if open {
                    Text(item.about)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if off {
                    Text(item.advice)
                        .font(.caption2)
                        .foregroundStyle(Self.color(item.level))
                }
            }
            .padding(.leading, 17)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
        }
    }

    static func color(_ level: EngineHealth.Level) -> Color {
        switch level {
        case .unknown: return .gray
        case .normal: return .green
        case .watch: return .orange
        case .high: return .red
        }
    }

    static func name(_ level: EngineHealth.Level) -> String {
        switch level {
        case .unknown: return "no data yet"
        case .normal: return "normal"
        case .watch: return "watch"
        case .high: return "check soon"
        }
    }
}

/// Dashboard: how many engine health items aren't normal; nothing while all is well.
struct EngineHealthBadge: View {
    @ObservedObject var health: EngineHealth

    var body: some View {
        let count = health.concerns.count
        if count > 0 {
            Label("\(count)", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(EngineHealthList.color(health.worst))
        }
    }
}
