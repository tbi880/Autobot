// SavedPlacesView.swift
// List of saved places: add, edit (tap), delete (swipe).

import SwiftUI

struct SavedPlacesView: View {
    @ObservedObject var store: SavedPlacesStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SavedPlace?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.places) { place in
                        Button { editing = place } label: { PlaceRow(place: place) }
                            .foregroundStyle(.primary)
                    }
                    .onDelete { store.delete(at: $0) }
                } footer: {
                    Text("Say the name when asked \"Where is our destination today?\". "
                         + "Exact street addresses start navigation right away; "
                         + "others are searched so you can pick.")
                }
            }
            .overlay {
                if store.places.isEmpty {
                    ContentUnavailableView("No saved places", systemImage: "mappin.and.ellipse",
                                           description: Text("Tap + to add one, e.g. home."))
                }
            }
            .navigationTitle("Saved places")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = SavedPlace(name: "", address: "") } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { place in
                PlaceEditor(place: place) { store.save($0) }
            }
        }
    }
}

private struct PlaceRow: View {
    let place: SavedPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(place.name).font(.headline)
            Text(place.address).font(.subheadline).foregroundStyle(.secondary)
            Label(place.isExactAddress ? "Starts navigation" : "Searches (address not exact)",
                  systemImage: place.isExactAddress ? "location.fill" : "magnifyingglass")
                .font(.caption)
                .foregroundStyle(place.isExactAddress ? Color.green : Color.orange)
        }
    }
}

private struct PlaceEditor: View {
    @State var place: SavedPlace
    let onSave: (SavedPlace) -> Void
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !place.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !place.address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name you'll say") {
                    TextField("e.g. home", text: $place.name)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    TextField("e.g. 6 Neilon Place, Northcross, Auckland",
                              text: $place.address, axis: .vertical)
                } header: {
                    Text("Address")
                } footer: {
                    if !place.address.isEmpty {
                        Text(place.isExactAddress
                             ? "Exact address: navigation will start straight away."
                             : "Not an exact street address (house number, street, suburb/city), "
                               + "so Google Maps will search it and you pick the result.")
                    }
                }
            }
            .navigationTitle("Saved place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(place)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
