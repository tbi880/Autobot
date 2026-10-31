// ELM327.swift
// The OBD2 Bluetooth adapter (KONNWEI, ELM327-compatible) and the text protocol it speaks.
//
// BLE layout (read from the adapter with LightBlue):
//   Service FFF0
//     FFF2  write without response   <- ASCII command + "\r"
//     FFF1  notify                   -> ASCII reply in chunks, finished by the ">" prompt
//
// The set-up follows what MAXOBD 1.1.03 (com.jiawei.maxobd, the adapter's own app) sends from its
// libobd.so (atz, ate0, atl0, atat1, atsp…), plus spaces and headers off so replies are easy to
// parse. MAXOBD identifies the car (Mazda CX-5 2.2 diesel) as ISO 15765-4 CAN with 11-bit IDs,
// engine ECU answering from 7E8.
//
// The app requests OBD2 speed (PID 0D) for stationary finder checks and uses the car's service-22
// selector signals for M/D. RPM (PID 0C) is queried only during i-stop's startup safety check; pedal,
// engine load, and estimated gear ratios are not used.
//
// The turn signals aren't a value to ask for but a frame the car broadcasts: the adapter listens to the
// bus for a moment instead ("ATMA", see Listening to the bus below and TurnSignals.swift).

import CoreBluetooth
import Foundation

/// One CAN frame heard while listening to the bus (ELM327 monitoring): when it arrived, and its data
/// bytes.
nonisolated struct CANFrame: Equatable {
    let time: Date
    let data: [UInt8]
}

enum ELM327 {
    static let service    = CBUUID(string: "FFF0")
    static let notifyChar = CBUUID(string: "FFF1")
    static let writeChar  = CBUUID(string: "FFF2")

    /// Ends every reply: the adapter is ready for the next command.
    static let prompt: Character = ">"

    // MARK: PIDs (mode 01)

    static let rpmPID: UInt8 = 0x0C             // engine RPM, 2 bytes
    static let speedPID: UInt8 = 0x0D           // road speed, km/h

    /// Data bytes after the PIDs used by wake checks and live requests.
    static let dataLength: [UInt8: Int] = [
        0x00: 4, 0x0C: 2, 0x0D: 1,
    ]

    // MARK: Commands

    /// Full reset, answered with the version ("ELM327 v1.5").
    static let reset = "ATZ"

    /// Sent once after the reset; each one is answered with "OK".
    static var setupCommands: [String] {
        var commands = [
            "ATE0",     // echo off
            "ATL0",     // no line feeds
            "ATS0",     // no spaces between bytes
            "ATH0",     // no CAN IDs in replies
            "ATAT1",    // adaptive timing: wait only as long as the ECU usually takes
            "ATSP" + AppConfig.OBD.protocolNumber,
        ]
        if let header = AppConfig.OBD.requestHeader {
            commands.append("ATSH" + header)   // ask the engine ECU only, not every ECU
        }
        return commands
    }

    /// The standard broadcast address, for questions any ECU may answer.
    static let broadcastHeader = "ATSH7DF"
    /// Mode 01 PID 00 (supported PIDs 01-20): any answer means the ECU is awake (ignition on).
    static let wakeCheck = "0100"
    /// A mode 01 request for one or more PIDs, e.g. [0x0D] -> "010D". `replyCount` adds a "1":
    /// one reply is enough, so the adapter answers without waiting for other ECUs.
    static func request(_ pids: [UInt8], replyCount: Bool) -> String {
        "01" + pids.map { String(format: "%02X", $0) }.joined() + (replyCount ? "1" : "")
    }

    // MARK: Gear selector (UDS service 22)

    /// UDS "service 22" (read data by identifier). The PCM answers "22 <DID>" with "62 <DID> <data…>".
    /// These DIDs are Mazda/Ford SkyActiv PCM identifiers, confirmed from community captures
    /// (OBDb) and matching what MAXOBD's Mazda module reads; see README.

    /// Gear-selector lever position (P/R/N/D/M), one byte. The only value that tells M from D.
    static let selectorDID = "1E23"
    /// The gear-selector lever. Read from the PCM with "221E23"; one byte, these raw values seen on
    /// Mazda/Ford SkyActiv PCMs: 0A manual (M), 2E drive (D), 32 neutral, 3C reverse, 46 park.
    /// Unmapped bytes stay `.unknown` so a firmware that uses other codes doesn't read as a gear.
    enum Selector: Equatable {
        case park, reverse, neutral, drive, manual
        case unknown(UInt8)

        init(byte: UInt8) {
            switch byte {
            case 0x0A: self = .manual
            case 0x2E: self = .drive
            case 0x32: self = .neutral
            case 0x3C: self = .reverse
            case 0x46: self = .park
            default:   self = .unknown(byte)
            }
        }

        /// True only in the manual gate (M), where Power Mode belongs.
        var isManual: Bool { self == .manual }

        var label: String {
            switch self {
            case .park: return "P"
            case .reverse: return "R"
            case .neutral: return "N"
            case .drive: return "D"
            case .manual: return "M"
            case .unknown(let b): return String(format: "0x%02X", b)
            }
        }
    }

    /// A UDS service-22 request: "221E23". `replyCount` adds a trailing "1" (one reply is enough),
    /// dropped like the mode-01 one if the adapter answers "?".
    static func request22(_ did: String, replyCount: Bool) -> String {
        "22" + did + (replyCount ? "1" : "")
    }

    // MARK: Is an ECU there? (UDS service 3E)

    /// UDS "tester present": a harmless "are you there?" that changes nothing. A reachable ECU
    /// answers "7E00", or refuses with "7F3E…"; either way it's there.
    static let testerPresent = "3E00"

    /// Whether a "3E00" reply came from an ECU (not "NO DATA", "CAN ERROR", …).
    static func isTesterPresentAnswer(_ reply: String) -> Bool {
        lines(reply).contains { $0.hasPrefix("7E00") || $0.hasPrefix("7F3E") }
    }

    // MARK: Listening to the bus (turn signals)

    /// "Monitor all": shows every CAN frame that gets through the receive filter (ATCRA), one per line,
    /// until any character is sent; the adapter throws that character away, finishes its line and
    /// answers with the prompt.
    static let monitorAll = "ATMA"
    /// Stops monitoring: a space, which the adapter would also just ignore at the prompt (a lone CR
    /// would repeat the last command, ATMA).
    static let stopMonitoring = " "
    /// CAN auto-formatting off while listening, so a broadcast frame's 8 data bytes show as they are
    /// (with it on, the first byte is taken for an ISO-TP length byte: the frame gets cut short or
    /// marked "<DATA ERROR"). On again for the requests; on is also the default after ATZ.
    static let formattingOff = "ATCAF0"
    static let formattingOn = "ATCAF1"
    /// CAN IDs in front of every line while listening, when the receive filter can't be trusted.
    static let headersOn = "ATH1"
    static let headersOff = "ATH0"
    /// Responses off/on (ATR0/ATR1): after a transmitted frame the adapter returns at once instead of
    /// waiting for a reply. Used when replaying a broadcast frame (the i-stop OFF button), which
    /// expects no reply.
    static let responsesOff = "ATR0"
    static let responsesOn = "ATR1"
    /// CAN id filter and mask while monitoring (ATCF / ATCM, 11-bit): a frame gets through when
    /// (id AND mask) == (filter AND mask). An aligned block of ids base..<base+size (size a power of two)
    /// is filter = base, mask = 7FF AND NOT (size − 1); mask 000 lets every id through.
    static func idFilter(_ filter: Int) -> String { String(format: "ATCF%03X", filter & 0x7FF) }
    static func idMask(_ mask: Int) -> String { String(format: "ATCM%03X", mask & 0x7FF) }
    /// Receive filters back to the adapter's defaults (CRA without an address, ELM327 v1.4+).
    static let resetReceiveFilters = "ATCRA"
    static let receiveAuto = "ATAR"

    /// Only frames with this 11-bit ID get through: "ATCRA09A".
    static func receiveFilter(_ id: String) -> String { "ATCRA" + id }

    /// A frame as shown while monitoring with spaces off: its data bytes ("0000200000000000"), after
    /// the 11-bit ID when headers are on ("09A0000200000000000"). nil for anything else ("BUFFER FULL",
    /// "STOPPED", "<DATA ERROR", a line cut short…).
    static func monitoredFrame(_ line: String, headers: Bool) -> (id: String?, data: [UInt8])? {
        let text = line.uppercased().filter { !$0.isWhitespace && $0 != prompt && $0 != "\0" }
        guard !text.isEmpty, text.allSatisfy({ $0.isHexDigit }) else { return nil }
        var digits = Array(text)
        var id: String?
        if headers {
            guard digits.count > 3 else { return nil }
            id = String(digits[0..<3])
            digits.removeFirst(3)
        }
        guard (2...16).contains(digits.count), digits.count % 2 == 0 else { return nil }
        var data: [UInt8] = []
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[i...(i + 1)]), radix: 16) else { return nil }
            data.append(byte)
        }
        return (id, data)
    }

    // MARK: Replies

    /// The values in a mode 01 reply, by PID: "410C0BB80D32" -> [0x0C: [0x0B, 0xB8], 0x0D: [0x32]].
    /// Starts at "41" + the first PID asked for and reads PID after PID while the length is known.
    static func values(in reply: String, first: UInt8) -> [UInt8: [UInt8]] {
        let marker = "41" + String(format: "%02X", first)
        var result: [UInt8: [UInt8]] = [:]
        for line in lines(reply) {
            guard let range = line.range(of: marker) else { continue }
            let hex = Array(line[range.lowerBound...].dropFirst(2))     // from the first PID on
            var bytes: [UInt8] = []
            var i = 0
            while i + 1 < hex.count, let byte = UInt8(String(hex[i...(i + 1)]), radix: 16) {
                bytes.append(byte)
                i += 2
            }
            var j = 0
            while j < bytes.count, let length = dataLength[bytes[j]], j + length < bytes.count {
                result[bytes[j]] = Array(bytes[(j + 1)...(j + length)])
                j += 1 + length
            }
        }
        return result
    }

    /// The PIDs a "0100 / 0120 / 0140 …" reply lists as supported (base 0x00 -> PIDs 01…20).
    /// nil if the reply has no such list ("NO DATA", …).
    static func supportedPIDs(in reply: String, base: UInt8) -> [UInt8]? {
        guard let data = values(in: reply, first: base)[base] else { return nil }
        let bits = data.reduce(UInt32(0)) { (result, byte) in (result << 8) | UInt32(byte) }
        return (0..<32).compactMap { (i: Int) -> UInt8? in
            guard bits & (UInt32(1) << UInt32(31 - i)) != 0 else { return nil }
            return UInt8(exactly: Int(base) + i + 1)
        }
    }

    /// PID 0C: rpm = (256 * A + B) / 4.
    static func rpm(_ data: [UInt8]) -> Double {
        Double(Int(data[0]) * 256 + Int(data[1])) / 4
    }

    /// The data bytes after "62<DID>" in a service-22 reply, or nil if the DID isn't echoed
    /// (e.g. "NO DATA", a negative response "7F22…", or a different DID). Longer replies come as
    /// several CAN frames (ISO-TP): a length line such as "00A", then "0:…", "1:…". Those are joined
    /// first and cut to the stated length, so the padding in the last frame isn't read as data.
    static func payload22(_ did: String, in reply: String) -> [UInt8]? {
        let marker = "62" + did.uppercased()
        let all = lines(reply)
        var statedLength: Int?
        var frames = ""
        for line in all {
            if line.count == 3, let length = Int(line, radix: 16) {
                statedLength = length
                continue
            }
            let chars = Array(line)
            if chars.count > 2, chars[1] == ":", chars[0].isHexDigit {
                frames += String(chars[2...])
            }
        }
        for text in (frames.isEmpty ? [] : [frames]) + all {
            guard let range = text.range(of: marker) else { continue }
            let hex = Array(text[range.upperBound...])
            var bytes: [UInt8] = []
            var i = 0
            while i + 1 < hex.count, let byte = UInt8(String(hex[i...(i + 1)]), radix: 16) {
                bytes.append(byte)
                i += 2
            }
            if !frames.isEmpty, text == frames, let statedLength, statedLength >= 3 {
                bytes = Array(bytes.prefix(statedLength - 3))      // minus "62" and the 2-byte DID
            }
            return bytes
        }
        return nil
    }

    /// The gear-selector lever from a "221E23" reply; nil if the PCM didn't answer the DID.
    static func selector(in reply: String) -> Selector? {
        guard let first = payload22(selectorDID, in: reply)?.first else { return nil }
        return Selector(byte: first)
    }

    /// Whether a "0100" reply is a real answer from an ECU (not "NO DATA", "UNABLE TO CONNECT"…).
    static func isECUAnswer(_ reply: String) -> Bool {
        supportedPIDs(in: reply, base: 0x00) != nil
    }

    /// Whether the adapter answered "OK".
    static func isOK(_ reply: String?) -> Bool {
        lines(reply ?? "").contains("OK")
    }

    /// Whether the adapter explicitly rejected a raw CAN transmit. With ATR0, a successful send
    /// normally produces only the prompt (an empty reply); ELM clones may still return one of these
    /// diagnostics when the frame could not be sent.
    static func hasCANTransmitError(_ reply: String) -> Bool {
        let errors: Set<String> = [
            "?", "ERROR", "CANERROR", "BUFFERFULL", "UNABLETOCONNECT", "BUSINIT:ERROR", "STOPPED",
        ]
        return lines(reply).contains { errors.contains($0) }
    }

    /// The adapter didn't understand the command.
    static func isUnknownCommand(_ reply: String) -> Bool {
        lines(reply).contains("?")
    }

    // MARK: UDS responses (service 10 session control, refusals)

    /// The negative response code in a reply to `service` ("7F2231" -> 0x31 for service 22); nil if
    /// the reply holds none. 31 means "no such DID" (in the current session).
    static func negativeResponseCode(service: UInt8, in reply: String) -> UInt8? {
        let marker = String(format: "7F%02X", service)
        for line in lines(reply) {
            guard let range = line.range(of: marker) else { continue }
            let code = line[range.upperBound...].prefix(2)
            if code.count == 2, let value = UInt8(code, radix: 16) { return value }
        }
        return nil
    }

    /// The data after a positive response to `service` + `subFunction` ("1003" -> "5003…"); nil if
    /// the reply holds none.
    static func positiveResponse(service: UInt8, subFunction: UInt8, in reply: String) -> [UInt8]? {
        let marker = String(format: "%02X%02X", service &+ 0x40, subFunction)
        for line in lines(reply) where line.hasPrefix(marker) {
            let hex = Array(line.dropFirst(marker.count))
            var bytes: [UInt8] = []
            var i = 0
            while i + 1 < hex.count, let byte = UInt8(String(hex[i...(i + 1)]), radix: 16) {
                bytes.append(byte)
                i += 2
            }
            return bytes
        }
        return nil
    }

    /// Whether a reply is the start of a reply of several frames (ISO-TP): a length line such as "00D"
    /// or a "0:" frame.
    static func startsLongReply(_ reply: String) -> Bool {
        lines(reply).contains { line in
            (line.count == 3 && Int(line, radix: 16) != nil) || line.hasPrefix("0:")
        }
    }

    /// What a UDS negative response code means, for the screen and the log.
    static func negativeResponseName(_ code: UInt8) -> String {
        switch code {
        case 0x10: return "general reject"
        case 0x11: return "service not supported"
        case 0x12: return "sub-function not supported"
        case 0x13: return "wrong message length"
        case 0x14: return "response too long"
        case 0x21: return "busy, ask again"
        case 0x22: return "conditions not correct"
        case 0x24: return "request sequence error"
        case 0x31: return "out of range (no such DID here)"
        case 0x33: return "security access denied"
        case 0x78: return "response pending"
        case 0x7E: return "sub-function not in this session"
        case 0x7F: return "service not in this session"
        default: return String(format: "code %02X", code)
        }
    }

    /// The adapter's name from the ATZ reply ("ELM327 v1.5"), for the log.
    static func version(in reply: String?) -> String {
        let parts = readableLines(reply)
        return parts.first { $0.uppercased().hasPrefix("ELM") } ?? parts.last ?? "no reply"
    }

    /// A reply on one line for the log: "NO DATA", "SEARCHING... / UNABLE TO CONNECT".
    static func readable(_ reply: String?) -> String {
        guard let reply else { return "no reply" }
        let parts = readableLines(reply)
        return parts.isEmpty ? "empty reply" : parts.joined(separator: " / ")
    }

    // MARK: Helpers

    /// The reply's lines in upper case, without spaces and the prompt: ["410C0BB8"].
    private static func lines(_ reply: String) -> [String] {
        reply.uppercased()
            .split(whereSeparator: { $0.isNewline })
            .map { (line: Substring) -> String in
                String(line.filter { $0.isASCII && !$0.isWhitespace && $0 != prompt && $0 != "\0" })
            }
            .filter { !$0.isEmpty }
    }

    /// The reply's lines as they are, trimmed, for the log.
    private static func readableLines(_ reply: String?) -> [String] {
        (reply ?? "")
            .split(whereSeparator: { $0.isNewline })
            .map { (line: Substring) -> String in
                line.filter { $0 != prompt && $0 != "\0" }.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

}
