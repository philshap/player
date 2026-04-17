//
//  LibraryView.swift
//  player
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Value-type row for the Table (no @Observable overhead)

struct TrackRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let bpm: Double?
    let rating: Int
    let duration: TimeInterval
    let playCount: Int
    let lastPlayedDate: Date?
    let dateAdded: Date

    var bpmSortValue: Double { bpm ?? 0 }
    var lastPlayedDateSortValue: Date { lastPlayedDate ?? .distantPast }

    init(_ track: Track) {
        self.id = track.id
        self.title = track.title
        self.artist = track.artist
        self.album = track.album
        self.bpm = track.bpm
        self.rating = track.rating
        self.duration = track.duration
        self.playCount = track.playCount
        self.lastPlayedDate = track.lastPlayedDate
        self.dateAdded = track.dateAdded
    }
}

// MARK: - NSItemProvider helper

extension NSItemProvider {

    func loadURL() async -> URL? {
        if hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await withCheckedContinuation { continuation in
                loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
                    guard let data,
                          let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: url)
                }
            }
        }

        if hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            return await withCheckedContinuation { continuation in
                loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                    if let str = item as? String,
                       let url = URL(string: str) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        return nil
    }
}


struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @Query(sort: [SortDescriptor(\Track.dateAdded, order: .reverse)]) private var tracks: [Track]
    @Query(sort: [SortDescriptor(\Playlist.name)]) private var playlists: [Playlist]

    @State private var searchText: String = ""
    @State private var sortOrder = [KeyPathComparator(\TrackRow.dateAdded, order: .reverse)]
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var displayedRows: [TrackRow] = []

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            trackTable
        }
        .searchable(text: $searchText, prompt: "Search by title, artist, or album")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isImporting = true
                } label: {
                    Label("Import Files", systemImage: "plus")
                }
                .disabled(appState.isPerformanceMode)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: LibraryManager.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    do {
                        try await appState.libraryManager.importFiles(urls: urls, modelContext: modelContext)
                    } catch {
                        importError = error.localizedDescription
                        showImportError = true
                    }
                }
            case .failure(let error):
                importError = error.localizedDescription
                showImportError = true
            }
        }
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let importError {
                Text(importError)
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .onAppear { recomputeDisplayedRows() }
        .onChange(of: tracks.count) { recomputeDisplayedRows() }
        .onChange(of: searchText) { recomputeDisplayedRows() }
        .onChange(of: sortOrder) { recomputeDisplayedRows() }
    }

    private func recomputeDisplayedRows() {
        let source = tracks
        let filtered: [Track]
        if searchText.isEmpty {
            filtered = source
        } else {
            let query = searchText.localizedLowercase
            filtered = source.filter { track in
                track.title.localizedCaseInsensitiveContains(query)
                || track.artist.localizedCaseInsensitiveContains(query)
                || track.album.localizedCaseInsensitiveContains(query)
            }
        }
        // Map to value types FIRST, then sort — avoids @Observable property access during sort
        let rows = filtered.map { TrackRow($0) }
        let sorted = rows.sorted(using: sortOrder)
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            displayedRows = sorted
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section("Library") {
                Label("All Tracks (\(tracks.count))", systemImage: "music.note.list")
            }

            Section("Playlists") {
                ForEach(playlists) { playlist in
                    Button {
                        openWindow(id: "playlist", value: playlist.id.uuidString)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: String.self) { droppedStrings, _ in
                        guard !appState.isPerformanceMode else { return false }
                        let trackIDs = droppedStrings.flatMap { TrackTransfer.decode($0) }
                        let droppedTracks = tracks.filter { trackIDs.contains($0.id) }
                        for track in droppedTracks {
                            appState.playlistManager.addTrack(track, to: playlist, modelContext: modelContext)
                        }
                        return !droppedTracks.isEmpty
                    }
                    .contextMenu {
                        if !appState.isPerformanceMode {
                            Button("Delete Playlist", role: .destructive) {
                                appState.playlistManager.deletePlaylist(playlist, modelContext: modelContext)
                            }
                        }
                    }
                }

                if !appState.isPerformanceMode {
                    Button {
                        let playlist = appState.playlistManager.createPlaylist(name: "New Playlist", modelContext: modelContext)
                        openWindow(id: "playlist", value: playlist.id.uuidString)
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160)
    }

    // MARK: - Track Table

    private var trackTable: some View {
        Table(displayedRows, selection: $selectedTrackIDs, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                Text(row.title)
                    .lineLimit(1)
                    .draggable(draggablePayload(for: row))
            }

            TableColumn("Artist", value: \.artist) { row in
                Text(row.artist)
                    .lineLimit(1)
            }

            TableColumn("Album", value: \.album) { row in
                Text(row.album)
                    .lineLimit(1)
            }

            TableColumn("BPM", value: \.bpmSortValue) { row in
                if let bpm = row.bpm {
                    Text(String(format: "%.0f", bpm))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 40, ideal: 50, max: 70)

            TableColumn("Rating", value: \.rating) { row in
                RatingView(rating: row.rating) { newRating in
                    updateTrackRating(id: row.id, rating: newRating)
                }
            }
            .width(min: 70, ideal: 90, max: 110)

            TableColumn("Duration", value: \.duration) { row in
                Text(formatDuration(row.duration))
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 65, max: 80)

            TableColumn("Plays", value: \.playCount) { row in
                Text("\(row.playCount)")
                    .monospacedDigit()
            }
            .width(min: 40, ideal: 50, max: 70)

            TableColumn("Last Played", value: \.lastPlayedDateSortValue) { row in
                if let lastPlayed = row.lastPlayedDate {
                    Text(lastPlayed, style: .date)
                }
            }
            .width(min: 80, ideal: 110, max: 140)

            TableColumn("Date Added", value: \.dateAdded) { row in
                Text(row.dateAdded, style: .date)
            }
            .width(min: 80, ideal: 110, max: 140)
        }
        .contextMenu(forSelectionType: UUID.self) { selectedIDs in
            let selectedTracks = tracks.filter { selectedIDs.contains($0.id) }
            if let firstTrack = selectedTracks.first {
                Button("Load in Preview") {
                    try? appState.previewPlayback.load(firstTrack)
                }

                Divider()

                Menu("Add to Playlist") {
                    ForEach(playlists) { playlist in
                        Button(playlist.name) {
                            for track in selectedTracks {
                                appState.playlistManager.addTrack(track, to: playlist, modelContext: modelContext)
                            }
                        }
                    }
                    if playlists.isEmpty {
                        Text("No playlists")
                    }
                }

                Divider()

                Button("Delete \(selectedTracks.count == 1 ? "Track" : "\(selectedTracks.count) Tracks") from Library", role: .destructive) {
                    deleteSelectedTracks(selectedTracks)
                }
                .disabled(appState.isPerformanceMode)
            }
        } primaryAction: { selectedIDs in
            if let trackID = selectedIDs.first,
               let track = tracks.first(where: { $0.id == trackID }) {
                try? appState.previewPlayback.load(track)
            }
        }
        .onDeleteCommand {
            guard !appState.isPerformanceMode else { return }
            let selectedTracks = tracks.filter { selectedTrackIDs.contains($0.id) }
            deleteSelectedTracks(selectedTracks)
        }
        .onDrop(of: [UTType.url.identifier, UTType.text.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Actions

    private func updateTrackRating(id: UUID, rating: Int) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        track.rating = rating
    }

    private func deleteSelectedTracks(_ selectedTracks: [Track]) {
        for track in selectedTracks {
            appState.libraryManager.deleteTrack(track, modelContext: modelContext)
        }
        selectedTrackIDs.removeAll()
    }

    // MARK: - Drag Support

    private func draggablePayload(for row: TrackRow) -> String {
        if selectedTrackIDs.contains(row.id) {
            return TrackTransfer.encode(trackIDs: Array(selectedTrackIDs))
        } else {
            return TrackTransfer.encode(trackIDs: [row.id])
        }
    }

    // MARK: - Drop Support

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        let appendQueue = DispatchQueue(label: "url.append.queue")

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data,
                          let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
                    else { return }
                    appendQueue.sync { urls.append(url) }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let str = item as? String,
                       let url = URL(string: str) {
                        appendQueue.sync { urls.append(url) }
                    }
                }
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Task {
                do {
                    try await appState.libraryManager.importFiles(
                        urls: urls,
                        modelContext: modelContext
                    )
                } catch {
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
        }

        return true
    }

    // MARK: - Helpers

    private func formatDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let totalSeconds = Int(interval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
