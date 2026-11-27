// ELMLink.swift
// The command channel to the OBD2 adapter: text out, text back up to the ">" prompt, one command at a
// time. It knows nothing about Bluetooth (OBDAdapter hands it a way to write and the bytes that come
// in) and nothing about what the commands mean (ELM327.swift, OBDAdapter).
//
//   send("010D\r") -> written -> bytes come in -> ">" -> the reply
//                                              -> nothing within the timeout -> nil
//
// After a timeout the adapter may still be busy with that command, and its reply may still be on the
// way. Sending the next command straight away would go wrong twice: the ELM327 drops whatever arrives
// while it's busy (the new command is lost, or cut), and the late reply would be taken for the new
// command's — every reply after that belongs to the command before it. So the next send first
// interrupts the adapter (a space: ignored at the prompt, stops a running command) and waits for the
// prompt (AppConfig.OBD.resyncTimeout). A reply that comes in while nothing is waiting for it is thrown
// away and counted.
//
// Every exchange is timed (onExchange); OBDTimings adds them up for the log.

import Foundation

final class ELMLink {

    /// One command and how long its reply took (`answered` false: no prompt within the timeout).
    nonisolated struct Exchange {
        let command: String
        let seconds: TimeInterval
        let answered: Bool
    }

    /// Every command, as its reply comes in or its timeout ends.
    var onExchange: ((Exchange) -> Void)?
    /// A reply arrived after its command had timed out (thrown away).
    var onLateReply: (() -> Void)?
    /// After a timeout the adapter was interrupted; `recovered`: it answered with the prompt.
    var onResync: ((_ recovered: Bool) -> Void)?
    /// While a command waits for its prompt: every complete line, as soon as it's in (the frames heard
    /// while monitoring the bus). Those lines are then left out of the reply.
    var onLine: ((String) -> Void)?

    /// Whether the adapter can be written to.
    var isOpen: Bool { transmit != nil }

    private var transmit: ((Data) -> Void)?
    private var received = ""                                   // reply so far, until ">"
    private var pending: CheckedContinuation<String?, Never>?   // the command waiting for ">"
    private var timeout: Task<Void, Never>?
    private var isSending = false          // between send's first and last line (the interrupt included)
    private var promptOwed = false         // the last command timed out: its prompt may still come
    private var isDeaf = false             // interrupting got no prompt either; nothing received since

    /// Without a prompt the reply is thrown away at this size, so it can't grow forever.
    private static let maxReplyBytes = 1024

    /// The adapter is connected: `transmit` writes to it.
    func open(transmit: @escaping (Data) -> Void) {
        self.transmit = transmit
        received = ""
        promptOwed = false
        isDeaf = false
    }

    /// The adapter is gone: the command waiting gets nil.
    func close() {
        transmit = nil
        finish(nil)
        received = ""
        onLine = nil
    }

    /// Writes `text` as it is and waits for the prompt. nil on a timeout, when the adapter is gone, or
    /// when another command is still waiting (commands go one at a time).
    func send(_ text: String, timeout seconds: TimeInterval) async -> String? {
        guard isOpen, !isSending, !Task.isCancelled else { return nil }
        isSending = true
        defer { isSending = false }
        if promptOwed, !isDeaf {
            let recovered = await exchange(ELM327.interrupt, timeout: AppConfig.OBD.resyncTimeout) != nil
            promptOwed = false
            isDeaf = !recovered                 // not again until the adapter says something
            onResync?(recovered)
            guard isOpen, !Task.isCancelled else { return nil }
        }
        let started = ContinuousClock.now
        let reply = await exchange(text, timeout: seconds)
        promptOwed = reply == nil && isOpen
        onExchange?(Exchange(command: text.trimmingCharacters(in: .whitespacesAndNewlines),
                             seconds: (ContinuousClock.now - started).inSeconds, answered: reply != nil))
        return reply
    }

    /// Writes the interrupt character without waiting: ends the command that is waiting (monitoring the
    /// bus), which then gets its prompt.
    func interrupt() {
        transmit?(Data(ELM327.interrupt.utf8))
    }

    /// Bytes from the adapter.
    func receive(_ data: Data) {
        isDeaf = false
        received += String(decoding: data, as: UTF8.self)
        if pending != nil, onLine != nil { deliverLines() }
        guard let end = received.firstIndex(of: ELM327.prompt) else {
            if received.utf8.count > Self.maxReplyBytes { received = "" }
            return
        }
        let reply = String(received[..<end])
        received = ""
        if pending != nil {
            finish(reply)
        } else if promptOwed {
            promptOwed = false                  // the reply to the command that timed out: too late
            onLateReply?()
        }
    }

    // MARK: Private

    private func exchange(_ text: String, timeout seconds: TimeInterval) async -> String? {
        guard let transmit else { return nil }
        received = ""
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish(nil)
        }
        return await withCheckedContinuation { continuation in
            pending = continuation
            transmit(Data(text.utf8))
        }
    }

    /// Hands the reply (nil: timeout or disconnected) to the command waiting for it.
    private func finish(_ reply: String?) {
        timeout?.cancel()
        timeout = nil
        let waiting = pending
        pending = nil
        waiting?.resume(returning: reply)
    }

    /// Every complete line before the prompt goes to onLine as soon as it's in.
    private func deliverLines() {
        while let end = received.firstIndex(where: { $0.isNewline }) {
            if let prompt = received.firstIndex(of: ELM327.prompt), prompt < end { return }
            let line = String(received[..<end])
            received.removeSubrange(...end)
            if !line.isEmpty { onLine?(line) }
        }
    }
}
