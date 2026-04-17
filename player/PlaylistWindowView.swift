//
//  PlaylistWindowView.swift
//  player
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PlaylistWindowView: View {
    let playlistID: String?
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]

    @Environment(\.dismiss) private var dismiss

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showDeleteConfirmation = false
    @State private var selectedTrackID: Track.ID?

    private var playlist: Playlist? {
        guard let playlistID,
              let uuid = UUID(uuidString: playlistID) else { return nil }
        return playlists.first { $0.id == uuid }
    }

    var body: some View {
        Group {
            if let playlist {
                playlistContent(playlist)
            } else {
                ContentUnavailableView(
                    "Playlist not found",
                    systemImage: "music.note.list",
                    description: Text("This playlist may have been deleted.")
                )
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onChange(of: playlist == nil) {
            if playlist == nil {
                dismiss()
            }
        }
    }

    // MARK: - Playlist Content

    @ViewBuilder
    private func playlistContent(_ playlist: Playlist) -> some View {
        let tracks = playlist.orderedTracks

        NavigationStack {
            VStack(spacing: 0) {
                if appState.isPerformanceMode {
                    performanceControls(tracks: tracks)
                    Divider()
                }

                Group {
                    if tracks.isEmpty {
                        ContentUnavailableView(
                            "No tracks",
                            systemImage: "music.note",
                            description: Text("Drag from Library to add tracks.")
                        )
                    } else {
                        trackList(tracks, playlist: playlist)
                    }
                }
            }
            .navigationTitle(playlist.name)
            .toolbar {
                toolbarContent(playlist)
            }
        }
        .sheet(isPresented: $isRenaming) {
            renameSheet(playlist)
        }
        .confirmationDialog(
            "Delete Playlist",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                appState.playlistManager.deletePlaylist(playlist, modelContext: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \"\(playlist.name)\"? This cannot be undone.")
        }
    }

    // MARK: - Performance Controls

    @ViewBuilder
    private func performanceControls(tracks: [Track]) -> some View {
        let main = appState.mainPlayback

        VStack(spacing: 6) {
            if let track = main.currentTrack {
                Text("\(track.title) — \(track.artist)")
                    .font(.headline)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Text(formatDuration(main.currentTime))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { main.currentTime },
                        set: { main.seek(to: $0) }
                    ),
                    in: 0...max(main.duration, 0.01)
                )

                Text(formatDuration(main.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
            }

            HStack(spacing: 20) {
                Button { main.previousTrack() } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }
                .buttonStyle(.borderless)

                Button { main.togglePlayPause() } label: {
                    Image(systemName: main.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                .buttonStyle(.borderless)

                Button { main.nextTrack() } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }
                .buttonStyle(.borderless)

                Button { main.stop() } label: {
                    Image(systemName: "stop.fill").font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    // MARK: - Track List

    @ViewBuilder
    private func trackList(_ tracks: [Track], playlist: Playlist) -> some View {
        List(selection: $selectedTrackID) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                PlaylistTrackRow(track: track, index: index, tracks: tracks)
                    .draggable(TrackTransfer.encode(trackIDs: [track.id]))
                    .tag(track.id)
                    .contextMenu {
                        trackContextMenu(index: index, track: track, tracks: tracks, playlist: playlist)
                    }
            }
            .onMove { source, destination in
                guard !appState.isPerformanceMode else { return }
                guard let sourceIndex = source.first else { return }
                let destIndex = destination > sourceIndex ? destination - 1 : destination
                appState.playlistManager.moveTrack(
                    in: playlist,
                    from: sourceIndex,
                    to: destIndex
                )
            }
            .onInsert(of: [.utf8PlainText]) { index, providers in
                handleInsert(at: index, providers: providers, playlist: playlist)
            }
            .moveDisabled(appState.isPerformanceMode)
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }

    private func handleInsert(at index: Int, providers: [NSItemProvider], playlist: Playlist) {
        for provider in providers {
            provider.loadObject(ofClass: NSString.self) { item, _ in
                guard let string = item as? String else { return }
                DispatchQueue.main.async {
                    let trackIDs = TrackTransfer.decode(string)
                    let allTracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
                    let droppedTracks = allTracks.filter { trackIDs.contains($0.id) }
                    for (offset, track) in droppedTracks.enumerated() {
                        appState.playlistManager.addTrack(track, to: playlist, modelContext: modelContext)
                        let lastIndex = playlist.entries.count - 1
                        if lastIndex > index + offset {
                            appState.playlistManager.moveTrack(
                                in: playlist,
                                from: lastIndex,
                                to: index + offset
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func trackContextMenu(index: Int, track: Track, tracks: [Track], playlist: Playlist) -> some View {
        Button("Play from Here") {
            appState.mainPlayback.loadTracks(tracks)
            appState.mainPlayback.play(from: index)
        }

        Button("Load in Preview") {
            try? appState.previewPlayback.load(track)
        }

        if !appState.isPerformanceMode {
            Divider()
            Button("Remove from Playlist", role: .destructive) {
                appState.playlistManager.removeTrack(
                    at: index,
                    from: playlist,
                    modelContext: modelContext
                )
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(_ playlist: Playlist) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if appState.isPerformanceMode {
                    appState.mode = .curation
                } else {
                    appState.mainPlayback.loadPlaylist(playlist)
                    appState.mode = .performance
                }
            } label: {
                Label(
                    appState.isPerformanceMode ? "Stop Performing" : "Perform",
                    systemImage: appState.isPerformanceMode ? "stop.circle.fill" : "play.circle.fill"
                )
            }
            .tint(appState.isPerformanceMode ? .orange : .accentColor)

            if !appState.isPerformanceMode {
                Button {
                    renameText = playlist.name
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Rename Sheet

    @ViewBuilder
    private func renameSheet(_ playlist: Playlist) -> some View {
        VStack(spacing: 16) {
            Text("Rename Playlist")
                .font(.headline)

            TextField("Playlist name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit {
                    commitRename(playlist)
                }

            HStack(spacing: 12) {
                Button("Cancel") {
                    isRenaming = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    commitRename(playlist)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private func commitRename(_ playlist: Playlist) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appState.playlistManager.renamePlaylist(playlist, to: trimmed)
        isRenaming = false
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Isolated Track Row View

/// Separate View struct so that playback observation (currentTrack, currentTime)
/// is isolated to each row. Updates to mainPlayback only re-render the affected
/// row(s), not the entire List/ForEach — preventing drag session disruption.
private struct PlaylistTrackRow: View {
    let track: Track
    let index: Int
    let tracks: [Track]

    @Environment(AppState.self) private var appState

    var body: some View {
        let main = appState.mainPlayback
        let isCurrentlyPlaying = main.currentTrack?.id == track.id
        let progress: Double = isCurrentlyPlaying && main.duration > 0
            ? main.currentTime / main.duration
            : 0

        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.body)
                    .fontWeight(isCurrentlyPlaying ? .semibold : .regular)
                    .lineLimit(1)

                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 100, alignment: .leading)

            Spacer()

            if let bpm = track.bpm {
                Text(String(format: "%.0f", bpm))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.5))
                    .frame(width: 40, alignment: .trailing)
            }

            RatingView(rating: track.rating) { newRating in
                track.rating = newRating
            }
            .frame(width: 70)

            HStack(spacing: 2) {
                Image(systemName: "play.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(track.playCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40, alignment: .trailing)

            Text(formatDuration(track.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .listRowBackground(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    if isCurrentlyPlaying {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: geo.size.width * progress)
                            .animation(.linear(duration: 0.1), value: progress)

                        Color.accentColor.opacity(0.05)
                    } else {
                        Color.clear
                    }
                }
            }
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
