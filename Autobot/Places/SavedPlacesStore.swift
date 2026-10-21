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
        places
            .filter { $0.isMentioned(in: text) }
            .max { SavedPlace.normalize($0.name).count < SavedPlace.normalize($1.name).count }
    }

    /// Finds the saved place whose name or address is within a small character edit
    /// distance of an extracted destination. If several places qualify, the closest
    /// proportional match wins.
    func place(similarTo text: String, maxCharacterDifferences: Int = 2) -> SavedPlace? {
        let spoken = Self.compact(text)
        guard !spoken.isEmpty, maxCharacterDifferences >= 0 else { return nil }

        return places.compactMap { place -> (place: SavedPlace, score: Double, distance: Int)? in
            let keys = [place.name, place.address]
                .map(Self.compact)
                .filter { !$0.isEmpty }
            return keys
                .map { key -> (place: SavedPlace, score: Double, distance: Int)? in
                    let distance = Self.editDistance(spoken, key)
                    guard distance <= maxCharacterDifferences else { return nil }
                    let length = max(spoken.count, key.count)
                    let score = length == 0 ? 1 : 1 - Double(distance) / Double(length)
                    return (place, score, distance)
                }
                .compactMap { $0 }
                .max {
                    if $0.score == $1.score { return $0.distance > $1.distance }
                    return $0.score < $1.score
                }
        }
        .max {
            if $0.score == $1.score { return $0.distance > $1.distance }
            return $0.score < $1.score
        }?
        .place
    }

    private static func compact(_ text: String) -> String {
        SavedPlace.normalize(text).filter { !$0.isWhitespace }
    }

    /// Levenshtein distance over extended grapheme clusters, so Chinese characters
    /// and composed accented letters each count as one character.
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitutionCost = leftCharacter == rightCharacter ? 0 : 1
                current[rightIndex + 1] = min(
                    min(previous[rightIndex + 1] + 1, current[rightIndex] + 1),
                    previous[rightIndex] + substitutionCost
                )
            }
            previous = current
        }
        return previous[right.count]
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
