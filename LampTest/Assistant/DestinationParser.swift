// DestinationParser.swift
// Decides whether the driver's reply names a destination, and extracts it.
//   1. Apple Intelligence (on-device), when this iPhone supports it (e.g. iPhone 17 Pro)
//   2. Keyword rules otherwise (e.g. iPhone 14 Pro), or if Apple Intelligence fails

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

final class DestinationParser {

    enum Engine: String {
        case appleIntelligence = "Apple Intelligence"
        case keywords = "Keyword rules"
    }

    var engine: Engine {
        AppleIntelligenceDestinationParser.isAvailable ? .appleIntelligence : .keywords
    }

    /// Returns the place to search for, or nil if the reply isn't a destination.
    func destination(in reply: String) async -> String? {
        if engine == .appleIntelligence,
           let verdict = await AppleIntelligenceDestinationParser.parse(reply) {
            switch verdict {
            case .destination(let place): return place
            case .notDestination: return nil
            }
        }
        // No Apple Intelligence, or it failed / timed out
        return KeywordDestinationParser.parse(reply)
    }
}

// MARK: - Apple Intelligence

nonisolated enum DestinationVerdict {
    case destination(String)
    case notDestination
}

#if canImport(FoundationModels)

@Generable
nonisolated struct DestinationIntent {
    @Guide(description: "true only if the driver is telling the assistant where they want to drive to")
    var isDestination: Bool

    @Guide(description: "The place to search for in a maps app, e.g. 'Sky Tower' or 'Countdown Ponsonby'. Empty if there is none.")
    var destination: String
}

nonisolated enum AppleIntelligenceDestinationParser {

    private static let instructions = """
        You are a car assistant. The assistant just asked the driver "Where is our destination today?". \
        Decide whether the driver's reply names a place to drive to. Replies that are chatter, \
        talking to a passenger, or refusing are not destinations. Keep the place name as spoken.
        """

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Returns nil if Apple Intelligence failed or timed out.
    static func parse(_ reply: String) async -> DestinationVerdict? {
        let intent = await withTimeout(seconds: AppConfig.Listening.aiTimeout) {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: "Driver's reply: \"\(reply)\"",
                generating: DestinationIntent.self
            )
            return response.content
        }
        guard let intent else { return nil }
        let place = intent.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return intent.isDestination && !place.isEmpty ? .destination(place) : .notDestination
    }
}

#else

nonisolated enum AppleIntelligenceDestinationParser {
    static var isAvailable: Bool { false }
    static func parse(_ reply: String) async -> DestinationVerdict? { nil }
}

#endif

// MARK: - Keyword rules

nonisolated enum KeywordDestinationParser {

    /// "take me to Sky Tower" -> "Sky Tower". Longest phrases first.
    private static let leadIns = [
        "i would like to go to", "i'd like to go to", "i want to go to", "we are going to",
        "we're going to", "directions to", "navigate to", "take me to", "let's go to", "lets go to",
        "drive to", "head to", "going to", "go to", "destination is",
        "导航到", "导航去", "带我去", "我要去", "我想去", "我们去",
    ]
    /// Single-character Chinese lead-ins, only matched at the very start ("去机场").
    private static let prefixLeadIns = ["去", "到"]

    private static let refusals = [
        "no", "nope", "nothing", "nowhere", "cancel", "never mind", "nevermind", "not now",
        "not sure", "i don't know", "don't know", "stop",
        "不用", "不去", "没有", "算了", "不知道",
    ]
    private static let maxPlaceWords = 6
    private static let maxBareReplyWords = 4

    static func parse(_ reply: String) -> String? {
        let text = clean(reply)
        let lower = text.lowercased()
        guard !text.isEmpty else { return nil }

        if refusals.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) { return nil }

        for leadIn in leadIns {
            if let range = text.range(of: leadIn, options: .caseInsensitive) {
                return place(String(text[range.upperBound...]))
            }
        }
        for leadIn in prefixLeadIns where text.hasPrefix(leadIn) {
            return place(String(text.dropFirst(leadIn.count)))
        }

        // A short bare answer such as "Sky Tower" or "home"
        if wordCount(text) <= maxBareReplyWords { return text }

        // Anything longer without a lead-in is treated as other conversation
        return nil
    }

    private static func place(_ raw: String) -> String? {
        var place = clean(raw)
        for filler in [" please", " thanks", " thank you", "吧", "谢谢"] where place.lowercased().hasSuffix(filler) {
            place = clean(String(place.dropLast(filler.count)))
        }
        guard !place.isEmpty, wordCount(place) <= maxPlaceWords else { return nil }
        return place
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}
