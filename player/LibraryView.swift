//
//  LibraryView.swift
//  player
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Value-type row for the Table (no @Observable overhead)

private let sharedDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

struct TrackRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let rating: Int
    let playCount: Int

    // Sort keys that strip leading "The " for natural ordering
    let sortableTitle: String
    let sortableAlbum: String

    // Stored sort values — no computed property overhead during sort
    let bpmSortValue: Double
    let duration: TimeInterval
    let lastPlayedSortValue: Date
    let dateAdded: Date

    // Album artwork thumbnail data
    let artworkData: Data?

    // Cue points
    let cuePointIn: TimeInterval?
    let cuePointOut: TimeInterval?

    // Pre-formatted display strings — no formatter overhead during rendering
    let formattedBPM: String
    let formattedDuration: String
    let formattedLastPlayed: String
    let formattedDateAdded: String
    let formattedCuePoints: String

    private static func stripLeadingThe(_ s: String) -> String {
        if s.count > 4, s.lowercased().hasPrefix("the ") {
            return String(s.dropFirst(4))
        }
        return s
    }

    init(_ track: Track) {
        self.id = track.id
        self.title = track.title
        self.artist = track.artist
        self.album = track.album
        self.sortableTitle = Self.stripLeadingThe(track.title)
        self.sortableAlbum = Self.stripLeadingThe(track.album)
        self.artworkData = track.artworkData
        self.rating = track.rating
        self.playCount = track.playCount
        self.bpmSortValue = track.bpm ?? 0
        self.duration = track.duration
        self.lastPlayedSortValue = track.lastPlayedDate ?? .distantPast
        self.dateAdded = track.dateAdded
        self.cuePointIn = track.cuePointIn
        self.cuePointOut = track.cuePointOut

        if let bpm = track.bpm {
            self.formattedBPM = String(format: "%.0f", bpm)
        } else {
            self.formattedBPM = ""
        }

        self.formattedDuration = track.duration.mmss()

        if let lastPlayed = track.lastPlayedDate {
            self.formattedLastPlayed = sharedDateFormatter.string(from: lastPlayed)
        } else {
            self.formattedLastPlayed = ""
        }

        self.formattedDateAdded = sharedDateFormatter.string(from: track.dateAdded)

        var cue = ""
        if let i = track.cuePointIn  { cue += "►\(i.mmss())" }
        if let o = track.cuePointOut { cue += (cue.isEmpty ? "" : " ") + "◼\(o.mmss())" }
        self.formattedCuePoints = cue
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
    /// Incremented on sort/filter changes to force Table recreation instead of diffing 500 rows.
    @State private var tableGeneration: Int = 0
    @State private var editingTrack: Track? = nil

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
        .onChange(of: tracks.count) { oldCount, newCount in
            // Only reset scroll when tracks are added (e.g. import) so the new
            // content is visible. Deletions preserve the current scroll position.
            recomputeDisplayedRows(resetScroll: newCount > oldCount)
        }
        .onChange(of: tracks.map(\.rating)) { recomputeDisplayedRows(resetScroll: false) }
        .onChange(of: searchText) { recomputeDisplayedRows() }
        .onChange(of: sortOrder) { recomputeDisplayedRows() }
        .sheet(item: $editingTrack) { track in
            TrackMetadataEditorView(track: track) {
                editingTrack = nil
                recomputeDisplayedRows(resetScroll: false)
            }
        }
    }

    private func recomputeDisplayedRows(resetScroll: Bool = true) {
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
        displayedRows = sorted
        if resetScroll {
            tableGeneration += 1
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
                    PlaylistSidebarRow(playlist: playlist, tracks: tracks, appState: appState, modelContext: modelContext, openWindow: openWindow)
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
                    .dropDestination(for: String.self) { droppedStrings, _ in
                        let trackIDs = droppedStrings.flatMap { TrackTransfer.decode($0) }
                        let droppedTracks = tracks.filter { trackIDs.contains($0.id) }
                        guard !droppedTracks.isEmpty else { return false }
                        let name = droppedTracks.count == 1
                            ? droppedTracks[0].title
                            : "New Playlist"
                        let playlist = appState.playlistManager.createPlaylist(name: name, modelContext: modelContext)
                        for track in droppedTracks {
                            appState.playlistManager.addTrack(track, to: playlist, modelContext: modelContext)
                        }
                        openWindow(id: "playlist", value: playlist.id.uuidString)
                        return true
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160)
    }

    // MARK: - Track Table

    private var trackTable: some View {
        Table(of: TrackRow.self, selection: $selectedTrackIDs, sortOrder: $sortOrder) {
            TableColumn("Art") { row in
                TrackArtworkView(data: row.artworkData, size: 28)
            }
            .width(36)

            TableColumn("Title", value: \.sortableTitle) { row in
                Text(row.title)
                    .lineLimit(1)
            }

            TableColumn("Artist", value: \.artist) { row in
                Text(row.artist)
                    .lineLimit(1)
            }

            TableColumn("Album", value: \.sortableAlbum) { row in
                Text(row.album)
                    .lineLimit(1)
            }

            TableColumn("BPM", value: \.bpmSortValue) { row in
                if row.formattedBPM.isEmpty {
                    Text("—")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(row.formattedBPM)
                        .monospacedDigit()
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
                Text(row.formattedDuration)
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 65, max: 80)

            TableColumn("Plays", value: \.playCount) { row in
                Text("\(row.playCount)")
                    .monospacedDigit()
            }
            .width(min: 40, ideal: 50, max: 70)

            TableColumn("Last Played", value: \.lastPlayedSortValue) { row in
                if row.formattedLastPlayed.isEmpty {
                    Text("")
                } else {
                    Text(row.formattedLastPlayed)
                }
            }
            .width(min: 80, ideal: 110, max: 140)

            TableColumn("Cue") { row in
                if !row.formattedCuePoints.isEmpty {
                    Text(row.formattedCuePoints)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 55, ideal: 90, max: 120)
        } rows: {
            ForEach(displayedRows) { row in
                TableRow(row)
                    .draggable(draggablePayload(for: row))
            }
        }
        .contextMenu(forSelectionType: UUID.self) { selectedIDs in
            let selectedTracks = tracks.filter { selectedIDs.contains($0.id) }
            if let firstTrack = selectedTracks.first {
                Button("Load in Preview") {
                    appState.previewPlayback.load(firstTrack)
                }

                // Cue point editing — set against current preview position
                let previewIsThisTrack = appState.previewPlayback.currentTrack?.id == firstTrack.id
                if previewIsThisTrack {
                    Divider()
                    Button("Set Cue In at Preview Position") {
                        firstTrack.cuePointIn = appState.previewPlayback.currentTime
                        recomputeDisplayedRows(resetScroll: false)
                    }
                    Button("Set Cue Out at Preview Position") {
                        firstTrack.cuePointOut = appState.previewPlayback.currentTime
                        recomputeDisplayedRows(resetScroll: false)
                    }
                }

                if firstTrack.cuePointIn != nil || firstTrack.cuePointOut != nil {
                    Button("Clear Cue Points") {
                        firstTrack.cuePointIn = nil
                        firstTrack.cuePointOut = nil
                        recomputeDisplayedRows(resetScroll: false)
                    }
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

                Button("Edit Metadata…") {
                    editingTrack = firstTrack
                }

                Button("Detect BPM") {
                    Task {
                        for track in selectedTracks {
                            let url = track.accessibleURL()
                            defer { url.stopAccessingSecurityScopedResource() }
                            if let bpm = await appState.libraryManager.detectBPM(url: url) {
                                track.bpm = bpm
                            }
                        }
                        recomputeDisplayedRows(resetScroll: false)
                    }
                }

                Button("Refresh Metadata") {
                    Task {
                        await appState.libraryManager.refreshMetadata(for: selectedTracks, modelContext: modelContext)
                        recomputeDisplayedRows(resetScroll: false)
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
                appState.previewPlayback.load(track)
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
        .id(tableGeneration)
    }

    // MARK: - Actions

    private func updateTrackRating(id: UUID, rating: Int) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        track.rating = rating
    }

    private func deleteSelectedTracks(_ selectedTracks: [Track]) {
        let deletedIDs = Set(selectedTracks.map(\.id))
        for track in selectedTracks {
            appState.libraryManager.deleteTrack(track, modelContext: modelContext)
        }
        selectedTrackIDs.subtract(deletedIDs)
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

}

// MARK: - Track Artwork View

struct TrackArtworkView: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        if let data, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.5))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Track Info View

/// Reusable artwork + title/artist label. Used in PlayerView and performance controls.
struct TrackInfoView: View {
    let track: Track
    var artworkSize: CGFloat = 52
    var titleFont: Font = .title3

    var body: some View {
        HStack(spacing: 12) {
            TrackArtworkView(data: track.artworkData, size: artworkSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(titleFont)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Playlist Sidebar Row

private struct PlaylistSidebarRow: View {
    let playlist: Playlist
    let tracks: [Track]
    let appState: AppState
    let modelContext: ModelContext
    let openWindow: OpenWindowAction

    @State private var isDropTargeted = false

    var body: some View {
        Button {
            openWindow(id: "playlist", value: playlist.id.uuidString)
        } label: {
            Label(playlist.name, systemImage: "music.note.list")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.2) : .clear)
        )
        .dropDestination(for: String.self) { droppedStrings, _ in
            let trackIDs = droppedStrings.flatMap { TrackTransfer.decode($0) }
            let droppedTracks = tracks.filter { trackIDs.contains($0.id) }
            for track in droppedTracks {
                appState.playlistManager.addTrack(track, to: playlist, modelContext: modelContext)
            }
            return !droppedTracks.isEmpty
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .contextMenu {
            if !appState.isPerformanceMode {
                Button("Delete Playlist", role: .destructive) {
                    appState.playlistManager.deletePlaylist(playlist, modelContext: modelContext)
                }
            }
        }
    }
}
