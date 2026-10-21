// SavedPlacesStore.swift
// The driver's saved places, kept on the phone (UserDefaults).

import Combine
import Foundation
import SwiftUI   // for Array.remove(atOffsets:)

final class SavedPlacesStore: ObservableObject {

    @Published private(set) var places: [SavedPlace] = []

    private let storageKey = "savedPlaces"

    init() {
        load()
    }

    // MARK: Editing

    /// Adds a new place, or updates the existing one with the same id.
    func save(_ place: SavedPlace) {
        let trimmed = SavedPlace(id: place.id,
                                 name: place.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 address: place.address.trimmingCharacters(in: .whitespacesAndNewlines))
        if let index = places.firstIndex(where: { $0.id == trimmed.id }) {
            places[index] = trimmed
        } else {
            places.append(trimmed)
        }
        persist()
    }

    func delete(at offsets: IndexSet) {
        places.remove(atOffsets: offsets)
        persist()
    }

    /// Replaces every place (restore from backup).
    func replaceAll(with newPlaces: [SavedPlace]) {
        places = newPlaces
        persist()
    }

    /// Adds places from a backup. A place with the same name (ignoring case/punctuation)
    /// takes the backup's address instead of being added twice.
    func merge(_ incoming: [SavedPlace]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for place in incoming {
            let key = SavedPlace.normalize(place.name)
            if let index = places.firstIndex(where: { $0.id == place.id || SavedPlace.normalize($0.name) == key }) {
                if places[index].address != place.address {
                    places[index].address = place.address
                    updated += 1
                }
            } else {
                places.append(place)
                added += 1
            }
        }
        persist()
        return (added, updated)
    }

    // MARK: Matching

    /// The saved place whose name appears in what was said. Longer names win,
    /// so "mum's home" beats "home".
    func place(mentionedIn text: String) -> SavedPlace? {
        let exactMatch = places
            .filter { $0.isMentioned(in: text) }
            .max { SavedPlace.normalize($0.name).count < SavedPlace.normalize($1.name).count }
        if let exactMatch { return exactMatch }
        return fuzzyMatch(for: text)
    }

    private func fuzzyMatch(for text: String) -> SavedPlace? {
        let spoken = SavedPlace.normalize(text)
        guard !spoken.isEmpty else { return nil }

        let candidates = places.compactMap { place -> (place: SavedPlace, score: Double)? in
            let name = SavedPlace.normalize(place.name)
            guard !name.isEmpty else { return nil }
            let distance = Self.levenshteinDistance(spoken, name)
            guard (1...2).contains(distance) else { return nil }
            let maxLength = max(spoken.count, name.count)
            guard maxLength > 0 else { return nil }
            let score = 1 - (Double(distance) / Double(maxLength))
            return (place, score)
        }

        return candidates.max { lhs, rhs in
            if lhs.score == rhs.score {
                return SavedPlace.normalize(lhs.place.name).count < SavedPlace.normalize(rhs.place.name).count
            }
            return lhs.score < rhs.score
        }?.place
    }

    private static func levenshteinDistance(_ left: String, _ right: String) -> Int {
        let leftChars = Array(left)
        let rightChars = Array(right)
        guard !leftChars.isEmpty else { return rightChars.count }
        guard !rightChars.isEmpty else { return leftChars.count }

        var previousRow = Array(0...rightChars.count)
        for (leftIndex, leftChar) in leftChars.enumerated() {
            var currentRow = [leftIndex + 1]
            currentRow.reserveCapacity(rightChars.count + 1)
            for (rightIndex, rightChar) in rightChars.enumerated() {
                let insertion = currentRow[rightIndex] + 1
                let deletion = previousRow[rightIndex + 1] + 1
                let substitution = previousRow[rightIndex] + (leftChar == rightChar ? 0 : 1)
                currentRow.append(min(insertion, deletion, substitution))
            }
            previousRow = currentRow
        }
        return previousRow[rightChars.count]
    }

    // MARK: Storage

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([SavedPlace].self, from: data) else { return }
        places = saved
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
