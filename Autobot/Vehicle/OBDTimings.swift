// OBDTimings.swift
// How long things take on the OBD2 link, added up for the log: every command's round trip (written ->
// ">" prompt), every round of live data, the time between two looks at the lights frame (what the turn
// signals and the wiper lever wait for), and the work between rounds, by who asked for it. Pure value
// code: ELMLink and OBDAdapter feed it, OBDAdapter writes one line a minute to OBDTimingLog and to the
// dashboard log when something is off (and now and then when all is well).
//
// What to look for after a long drive, when the app lags behind the car:
//   - commands slow, timeouts, late replies -> the adapter or the Bluetooth link (heat, distance)
//   - rounds or the gap between looks long while commands are fast -> work between rounds holds the
//     adapter too long; the line names it
//   - "app held up" -> the phone itself (main thread busy, thermal throttling), not the link

import Foundation

nonisolated struct OBDTimings {

    /// How many, how long together, and the longest one (with what it was).
    nonisolated struct Span: Equatable {
        private(set) var count = 0
        private(set) var total: TimeInterval = 0
        private(set) var longest: TimeInterval = 0
        private(set) var longestLabel = ""

        var mean: TimeInterval { count > 0 ? total / Double(count) : 0 }

        mutating func add(_ seconds: TimeInterval, label: String = "") {
            count += 1
            total += seconds
            if seconds > longest || count == 1 {
                longest = seconds
                longestLabel = label
            }
        }
    }

    private(set) var commands = Span()
    private(set) var timeouts = 0
    /// Replies that came in after their command's timeout (thrown away by ELMLink).
    private(set) var lateReplies = 0
    /// Times the adapter was interrupted after a timeout, and how many of those got no prompt back.
    private(set) var resyncs = 0
    private(set) var failedResyncs = 0
    private(set) var rounds = Span()
    /// From the end of one look at the lights frame to the end of the next.
    private(set) var lookGaps = Span()
    /// Frames of the lights frame heard, and for how long the bus was listened to.
    private(set) var frames = 0
    private(set) var listened: TimeInterval = 0
    /// Work between rounds, by who asked ("DPFRecorder").
    private(set) var jobs: [String: Span] = [:]
    /// The app's own delays: how much later than asked a short sleep on the main actor came back.
    private(set) var stalls = Span()

    var isEmpty: Bool { commands.count == 0 && rounds.count == 0 }

    /// Something a healthy link doesn't show: worth a line in the dashboard log right away.
    var isTroubled: Bool {
        timeouts > 0 || lateReplies > 0 || resyncs > 0 || stalls.count > 0
            || commands.longest >= AppConfig.OBD.slowCommand
            || lookGaps.longest >= AppConfig.OBD.slowLookGap
    }

    mutating func command(_ exchange: ELMLink.Exchange) {
        commands.add(exchange.seconds, label: exchange.command)
        if !exchange.answered { timeouts += 1 }
    }

    mutating func lateReply() { lateReplies += 1 }

    mutating func resync(recovered: Bool) {
        resyncs += 1
        if !recovered { failedResyncs += 1 }
    }

    mutating func round(_ seconds: TimeInterval) { rounds.add(seconds) }

    /// One look at the lights frame: `gap` since the look before ended (nil for the first one), and what
    /// held the adapter longest in between.
    mutating func look(gap: TimeInterval?, held: String, frames heard: Int, listened seconds: TimeInterval) {
        if let gap { lookGaps.add(gap, label: held) }
        frames += heard
        listened += seconds
    }

    mutating func job(_ owner: String, _ seconds: TimeInterval) {
        jobs[owner, default: Span()].add(seconds)
    }

    mutating func stall(_ seconds: TimeInterval) { stalls.add(seconds) }

    /// One line for the log: "412 commands 38 ms (longest 310 ms 221E12) · 58 rounds 1.02 s (longest
    /// 1.6 s) · lights every 1.0 s (longest gap 1.9 s) · 09A 9.8/s · DPFRecorder 6× longest 0.7 s".
    func summary(lightsFrame: String) -> String {
        var parts: [String] = []
        var line = "\(commands.count) commands " + Self.text(commands.mean)
        if commands.count > 0 {
            line += " (longest " + Self.text(commands.longest) + " " + commands.longestLabel + ")"
        }
        parts.append(line)
        if timeouts > 0 { parts.append("\(timeouts) timeouts") }
        if lateReplies > 0 { parts.append("\(lateReplies) late replies") }
        if resyncs > 0 {
            parts.append("\(resyncs) resyncs" + (failedResyncs > 0 ? " (\(failedResyncs) without a prompt)" : ""))
        }
        if rounds.count > 0 {
            parts.append("\(rounds.count) rounds " + Self.text(rounds.mean) + " (longest " + Self.text(rounds.longest) + ")")
        }
        if lookGaps.count > 0 {
            var gap = "lights every " + Self.text(lookGaps.mean) + " (longest gap " + Self.text(lookGaps.longest)
            if !lookGaps.longestLabel.isEmpty { gap += ", " + lookGaps.longestLabel }
            parts.append(gap + ")")
        }
        if listened > 0 {
            parts.append(lightsFrame + String(format: " %.1f/s", Double(frames) / listened))
        }
        for owner in jobs.keys.sorted() {
            guard let span = jobs[owner] else { continue }
            parts.append("\(owner) \(span.count)× longest " + Self.text(span.longest))
        }
        if stalls.count > 0 {
            parts.append("app held up \(stalls.count)× (longest " + Self.text(stalls.longest) + ")")
        }
        return parts.joined(separator: " · ")
    }

    /// "38 ms" below a second, "1.6 s" from there.
    static func text(_ seconds: TimeInterval) -> String {
        seconds < 0.9995 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.1f s", seconds)
    }
}

/// The timing lines of the latest drives, kept in a small text file (Application Support/OBDTiming) so
/// a long drive can be looked at afterwards: the DPF screen's export sends it along.
enum OBDTimingLog {

    /// The file, once something has been written to it.
    static var exportURL: URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    /// Adds a line with the time in front. Over AppConfig.OBD.timingLogMaxBytes the older half is dropped.
    static func append(_ line: String, at date: Date = Date()) {
        guard let url else { return }
        append(line, to: url, maxBytes: AppConfig.OBD.timingLogMaxBytes, at: date)
    }

    static func append(_ line: String, to url: URL, maxBytes: Int, at date: Date = Date()) {
        guard let data = (stamp.string(from: date) + " " + line + "\n").data(using: .utf8) else { return }
        let path = url.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.write(contentsOf: data)
        try? handle.close()
        if Int(size) > maxBytes { dropOlderHalf(of: url) }
    }

    private static let url: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("OBDTiming", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        return directory.appendingPathComponent("autobot-obd-timing.log")
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Keeps the newer half, from the start of a line.
    private static func dropOlderHalf(of url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let middle = data.count / 2
        guard let newline = data[middle...].firstIndex(of: UInt8(ascii: "\n")) else { return }
        try? data[(newline + 1)...].write(to: url, options: .atomic)
    }
}
