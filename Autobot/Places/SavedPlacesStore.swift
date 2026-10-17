// SavedPlacesStore.swift
// The driver's saved places, kept on the phone (UserDefaults).

import Combine
import Foundation

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
