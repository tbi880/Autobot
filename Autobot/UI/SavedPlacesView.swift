// SavedPlacesView.swift
// List of saved places: add, edit (tap), delete (swipe left), set as Home / Work (swipe right,
// or in the editor).

import SwiftUI
import UniformTypeIdentifiers

struct SavedPlacesView: View {
    @ObservedObject var store: SavedPlacesStore
    let backup: BackupManager
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SavedPlace?

    // Import flow: pick file -> choose merge/replace -> show result
    @State private var showingImporter = false
    @State private var pendingBackup: AppBackup?
    @State private var resultMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.places) { place in
                        Button { editing = place } label: { PlaceRow(place: place) }
                            .foregroundStyle(.primary)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                ForEach(SavedPlace.Role.allCases) { role in
                                    roleButton(role, for: place)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.delete(place) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                ForEach(SavedPlace.Role.allCases) { role in
                                    roleButton(role, for: place)
                                }
                            }
                    }
                    .onDelete { store.delete(at: $0) }
                } footer: {
                    Text("Say the name when asked \"Where is our destination today?\". "
                         + "Exact street addresses start navigation right away; "
                         + "others are searched so you can pick.\n\n"
                         + "Swipe right to mark one place as Home and one as Work. "
                         + "On weekdays from 7 to 10 am, when the car connects near Home, "
                         + "navigation to Work starts without asking.")
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
                ToolbarItem(placement: .secondaryAction) {
                    ShareLink(item: BackupFile(backup: backup.makeBackup()),
                              preview: SharePreview("Autobot backup")) {
                        Label("Export backup (JSON)", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { showingImporter = true } label: {
                        Label("Import backup", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(item: $editing) { place in
                PlaceEditor(place: place) { store.save($0) }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                do {
                    pendingBackup = try backup.readBackup(at: result.get())
                } catch {
                    resultMessage = error.localizedDescription
                }
            }
            .confirmationDialog("Import backup", isPresented: isAskingImportMode, titleVisibility: .visible) {
                Button("Merge with my places") { restore(.merge) }
                Button("Replace all my places", role: .destructive) { restore(.replace) }
                Button("Cancel", role: .cancel) { pendingBackup = nil }
            } message: {
                Text(importSummary)
            }
            .alert("Import", isPresented: isShowingResult) {
                Button("OK") { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }
}

private extension SavedPlacesView {

    /// "Set as Home" / "Not Home" (and the same for Work).
    func roleButton(_ role: SavedPlace.Role, for place: SavedPlace) -> some View {
        let isSet = place.role == role
        return Button {
            store.setRole(isSet ? nil : role, for: place)
        } label: {
            Label(isSet ? "Not \(role.title)" : "Set as \(role.title)",
                  systemImage: isSet ? "xmark" : role.systemImage)
        }
        .tint(role == .home ? .blue : .indigo)
    }

    var isAskingImportMode: Binding<Bool> {
        Binding(get: { pendingBackup != nil }, set: { if !$0 { pendingBackup = nil } })
    }

    var isShowingResult: Binding<Bool> {
        Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })
    }

    var importSummary: String {
        guard let b = pendingBackup else { return "" }
        let count = b.data.savedPlaces?.count ?? 0
        let date = b.exportedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(count) saved places, exported \(date)."
    }

    func restore(_ mode: BackupManager.RestoreMode) {
        guard let pending = pendingBackup else { return }
        pendingBackup = nil
        resultMessage = backup.restore(pending, mode: mode)
    }
}

private struct PlaceRow: View {
    let place: SavedPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(place.name).font(.headline)
                if let role = place.role {
                    Label(role.title, systemImage: role.systemImage)
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
            }
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
                    Picker("Use as", selection: $place.role) {
                        Text("None").tag(SavedPlace.Role?.none)
                        ForEach(SavedPlace.Role.allCases) { role in
                            Text(role.title).tag(SavedPlace.Role?.some(role))
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Use as")
                } footer: {
                    Text("Only one place can be Home and one Work; choosing it here moves it from "
                         + "the other place. Weekdays 7-10 am near Home: navigation to Work "
                         + "starts without asking.")
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
