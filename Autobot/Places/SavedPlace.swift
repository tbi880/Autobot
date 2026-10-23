// SavedPlace.swift
// A place the driver saved by hand, e.g. name "home", address "6 Neilon Place, Northcross, Auckland".
// One place can also be marked as Home and one as Work (used by the weekday-morning commute).

import Foundation

nonisolated struct SavedPlace: Identifiable, Codable, Equatable, Hashable {

    /// What the place is for. At most one place is Home and one is Work (SavedPlacesStore keeps it so).
    nonisolated enum Role: String, Codable, CaseIterable, Identifiable {
        case home
        case work

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Home"
            case .work: return "Work"
            }
        }

        var systemImage: String {
            switch self {
            case .home: return "house.fill"
            case .work: return "briefcase.fill"
            }
        }
    }

    var id = UUID()
    var name: String
    var address: String
    var role: Role?

    init(id: UUID = UUID(), name: String, address: String, role: Role? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.role = role
    }

    /// Lenient decoding for backups: "id" and "role" may be missing (e.g. a hand-written file
    /// or an older backup); an unknown role is ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        role = try? c.decodeIfPresent(Role.self, forKey: .role)
    }

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
