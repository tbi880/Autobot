// SavedPlace.swift
// A place the driver saved by hand, e.g. name "home", address "6 Neilon Place, Northcross, Auckland".

import Foundation

nonisolated struct SavedPlace: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var address: String

    /// True when the address looks like an exact street address ("6 Neilon Place, Northcross, Auckland"):
    /// a house number followed by a street name, plus at least a suburb or city.
    /// Exact addresses start navigation straight away; anything vaguer is searched instead.
    var isExactAddress: Bool {
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let street = parts.first else { return false }
        // "6 Neilon Place", "12A Queen Street", "3/45 Smith Road"
        return street.range(of: #"^\d+[A-Za-z]?(/\d+[A-Za-z]?)?\s+\p{L}{2,}"#, options: .regularExpression) != nil
    }

    /// True if `text` mentions this place's name as whole word(s), e.g. "take me home" for "home".
    func isMentioned(in text: String) -> Bool {
        let name = Self.normalize(self.name)
        guard !name.isEmpty else { return false }
        let spoken = Self.normalize(text)
        // Names in Chinese/Japanese have no spaces between words: plain containment
        if name.unicodeScalars.contains(where: { $0.value > 0x2E7F }) {
            return spoken.contains(name)
        }
        return " \(spoken) ".contains(" \(name) ")
    }

    /// Lowercased, punctuation removed, single spaces.
    static func normalize(_ text: String) -> String {
        let cleaned = text.lowercased().unicodeScalars.map {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}
