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
