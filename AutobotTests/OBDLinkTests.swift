// OBDLinkTests.swift
// The OBD2 link without a car: ELMLink against a scripted adapter (replies in chunks, late replies,
// timeouts), the turn signals' hold limit, and the timing lines.

import Foundation
import Testing
@testable import Autobot

/// An ELMLink with everything it writes and reports kept, and a way to play the adapter.
private final class ScriptedAdapter {
    let link = ELMLink()
    private(set) var written: [String] = []
    private(set) var exchanges: [ELMLink.Exchange] = []
    private(set) var lateReplies = 0
    private(set) var resyncs: [Bool] = []

    init() {
        link.open { [unowned self] data in self.written.append(String(decoding: data, as: UTF8.self)) }
        link.onExchange = { [unowned self] exchange in self.exchanges.append(exchange) }
        link.onLateReply = { [unowned self] in self.lateReplies += 1 }
        link.onResync = { [unowned self] recovered in self.resyncs.append(recovered) }
    }

    /// Bytes from the adapter.
    func answer(_ text: String) {
        link.receive(Data(text.utf8))
    }

    /// Lets the command just sent get written.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }
}

@Suite struct ELMLinkTests {

    @Test func replyArrivesInChunks() async {
        let adapter = ScriptedAdapter()
        async let reply = adapter.link.send("010D1\r", timeout: 1)
        await adapter.settle()
        adapter.answer("410D")
        adapter.answer("32\r\r")
        adapter.answer(">")
        #expect(await reply == "410D32\r\r")
        #expect(adapter.written == ["010D1\r"])
        #expect(adapter.exchanges.count == 1)
        #expect(adapter.exchanges.first?.command == "010D1")
        #expect(adapter.exchanges.first?.answered == true)
    }

    /// The reply to a command that timed out comes in before the next command: thrown away, and the
    /// next command goes out without an interrupt (the prompt already came).
    @Test func lateReplyBeforeTheNextCommandIsThrownAway() async {
        let adapter = ScriptedAdapter()
        #expect(await adapter.link.send("221E12\r", timeout: 0.05) == nil)
        adapter.answer("621E1203\r\r>")
        #expect(adapter.lateReplies == 1)

        async let reply = adapter.link.send("010D1\r", timeout: 1)
        await adapter.settle()
        #expect(adapter.written == ["221E12\r", "010D1\r"])
        adapter.answer("410D40\r\r>")
        #expect(await reply == "410D40\r\r")
        #expect(adapter.resyncs.isEmpty)
    }

    /// The reply is still on its way when the next command is asked for: the adapter is interrupted
    /// first, the late reply ends that, and only then the command goes out and gets its own reply.
    @Test func lateReplyIsNeverTakenForTheNextCommand() async {
        let adapter = ScriptedAdapter()
        _ = await adapter.link.send("221E12\r", timeout: 0.05)

        async let reply = adapter.link.send("010D1\r", timeout: 1)
        await adapter.settle()
        #expect(adapter.written == ["221E12\r", ELM327.interrupt])     // the command is held back
        adapter.answer("621E1203\r\r>")
        await adapter.settle()
        #expect(adapter.written == ["221E12\r", ELM327.interrupt, "010D1\r"])
        adapter.answer("410D40\r\r>")
        #expect(await reply == "410D40\r\r")
        #expect(adapter.resyncs == [true])
        #expect(adapter.lateReplies == 0)
    }

    /// An adapter that says nothing at all is interrupted once, not before every command.
    @Test func silentAdapterIsInterruptedOnlyOnce() async {
        let adapter = ScriptedAdapter()
        _ = await adapter.link.send("0100\r", timeout: 0.05)
        _ = await adapter.link.send("0100\r", timeout: 0.05)
        #expect(adapter.resyncs == [false])

        let started = ContinuousClock.now
        _ = await adapter.link.send("0100\r", timeout: 0.05)
        #expect((ContinuousClock.now - started).inSeconds < AppConfig.OBD.resyncTimeout)
        #expect(adapter.written == ["0100\r", ELM327.interrupt, "0100\r", "0100\r"])
        #expect(adapter.exchanges.filter { !$0.answered }.count == 3)
    }

    /// Monitoring the bus: complete lines come out as they arrive; the interrupt is written at once.
    @Test func monitoredLinesAreDeliveredAsTheyComeIn() async {
        let adapter = ScriptedAdapter()
        var lines: [String] = []
        adapter.link.onLine = { lines.append($0) }
        async let reply = adapter.link.send("ATMA\r", timeout: 1)
        await adapter.settle()
        adapter.answer("0000200000000000\r00002000")
        #expect(lines == ["0000200000000000"])
        adapter.answer("00000000\r")
        #expect(lines == ["0000200000000000", "0000200000000000"])
        adapter.link.interrupt()
        adapter.answer("\r>")
        #expect(await reply != nil)
        #expect(adapter.written == ["ATMA\r", ELM327.interrupt])
    }

    @Test func closingEndsTheCommandWaiting() async {
        let adapter = ScriptedAdapter()
        async let reply = adapter.link.send("0100\r", timeout: 5)
        await adapter.settle()
        adapter.link.close()
        #expect(await reply == nil)
        #expect(await adapter.link.send("0100\r", timeout: 0.05) == nil)
        #expect(adapter.written == ["0100\r"])                         // nothing written once closed
    }
}

@Suite struct TurnSignalHoldTests {

    private func frame(_ start: Date, _ offset: TimeInterval, lamp: UInt8) -> CANFrame {
        CANFrame(time: start.addingTimeInterval(offset), data: [0, 0, lamp, 0, 0, 0, 0, 0])
    }

    /// A flash no look confirms ends holdLimit after the last one heard, by the clock.
    @Test func flashEndsByTheClockWhenNoLookComes() {
        var detector = TurnSignalDetector()
        let start = Date()
        let frames = [frame(start, 0, lamp: 0x20), frame(start, 0.1, lamp: 0x20), frame(start, 0.2, lamp: 0x00)]
        #expect(detector.finish(frames, ended: start.addingTimeInterval(0.2)) == .left)

        let hold = AppConfig.TurnSignals.holdLimit
        #expect(detector.expire(at: start.addingTimeInterval(0.2 + hold - 0.5)) == .left)
        #expect(detector.expire(at: start.addingTimeInterval(0.2 + hold + 0.1)) == .off)
        #expect(detector.state == .off)
    }
}

@Suite struct OBDTimingsTests {

    @Test func aHealthyMinute() {
        var timings = OBDTimings()
        #expect(timings.isEmpty)
        timings.command(.init(command: "010D1", seconds: 0.040, answered: true))
        timings.command(.init(command: "221E12", seconds: 0.060, answered: true))
        timings.round(1.0)
        timings.round(1.4)
        timings.look(gap: nil, held: "", frames: 5, listened: 0.5)
        timings.look(gap: 1.2, held: "DPFRecorder 700 ms", frames: 5, listened: 0.5)
        timings.job("DPFRecorder", 0.7)

        #expect(!timings.isTroubled)
        let line = timings.summary(lightsFrame: "09A")
        #expect(line.contains("2 commands 50 ms (longest 60 ms 221E12)"))
        #expect(line.contains("2 rounds 1.2 s (longest 1.4 s)"))
        #expect(line.contains("lights every 1.2 s (longest gap 1.2 s, DPFRecorder 700 ms)"))
        #expect(line.contains("09A 10.0/s"))
        #expect(line.contains("DPFRecorder 1× longest 700 ms"))
    }

    @Test func troubleIsNamed() {
        var timings = OBDTimings()
        timings.command(.init(command: "22F47A", seconds: 1.5, answered: false))
        timings.lateReply()
        timings.resync(recovered: false)
        timings.stall(0.4)
        timings.look(gap: 12.3, held: "DPFHistoryFinder 11.8 s", frames: 0, listened: 0.4)

        #expect(timings.isTroubled)
        let line = timings.summary(lightsFrame: "09A")
        #expect(line.contains("1 timeouts"))
        #expect(line.contains("1 late replies"))
        #expect(line.contains("1 resyncs (1 without a prompt)"))
        #expect(line.contains("longest gap 12.3 s, DPFHistoryFinder 11.8 s"))
        #expect(line.contains("app held up 1× (longest 400 ms)"))
    }

    /// The file keeps its newest lines: over the limit the older half goes, from a whole line on.
    @Test func timingLogDropsItsOlderHalf() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timing-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        for index in 0..<40 {
            OBDTimingLog.append("OBD timing: line \(index)", to: url, maxBytes: 600)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(text.utf8.count < 1400)
        #expect(lines.last?.hasSuffix("line 39") == true)
        #expect(lines.first?.contains(" OBD timing: line ") == true)
        #expect(lines.first?.first?.isNumber == true)                  // starts with a whole time stamp
    }
}
