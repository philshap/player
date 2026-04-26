//
//  PlaylistWindowView.swift
//  player
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PlaylistWindowView: View {
    let playlistID: String
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]

    @Environment(\.dismiss) private var dismiss

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showDeleteConfirmation = false
    @State private var selectedTrackID: Track.ID?

    private var playlist: Playlist? {
        guard let uuid = UUID(uuidString: playlistID) else { return nil }
        return playlists.first { $0.id == uuid }
    }

    var body: some View {
        Group {
            if let playlist {
                playlistContent(playlist)
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
                if appState.isPerformanceMode && appState.performingPlaylistID == playlist.id {
                    PerformanceControlsView()
                    Divider()
                }

                Group {
                    if tracks.isEmpty {
                        ContentUnavailableView(
                            "No tracks",
                            systemImage: "music.note",
                            description: Text("Drag from Library to add tracks.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .dropDestination(for: String.self) { droppedStrings, _ in
                            let trackIDs = droppedStrings.flatMap { TrackTransfer.decode($0) }
                            let allTracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
                            let droppedTracks = allTracks.filter { trackIDs.contains($0.id) }
                            for track in droppedTracks {
                                appState.playlistManager.addTrack(track, to: playlist, modelContext: modelContext)
                            }
                            return !droppedTracks.isEmpty
                        }
                    } else {
                        trackList(tracks, playlist: playlist)
                    }
                }

                if !tracks.isEmpty {
                    Divider()
                    PlaylistStatsBar(tracks: tracks)
                }
            }
            .navigationTitle(
                playlist.name + " • " +
                Duration.seconds(
                    playlist.orderedTracks.map(\.duration).reduce(0, +)
                )
                .formatted(.time(pattern: .hourMinuteSecond))
            )
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

    // MARK: - Track List

    @ViewBuilder
    private func trackList(_ tracks: [Track], playlist: Playlist) -> some View {
        List(selection: $selectedTrackID) {
            let isActivePlaylist = appState.isPerformanceMode && appState.performingPlaylistID == playlist.id
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                PlaylistTrackRow(track: track, index: index, isCurrentlyPlaying: isActivePlaylist && appState.mainPlayback.currentTrack?.id == track.id, isActivePlaylist: isActivePlaylist)
                    .draggable(TrackTransfer.encode(trackIDs: [track.id]))
                    .tag(track.id)
                    .contextMenu {
                        trackContextMenu(index: index, track: track, tracks: tracks, playlist: playlist)
                    }
            }
            .onMove { source, destination in
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
            appState.mainPlayback.loadPlaylist(playlist)
            appState.mainPlayback.play(from: index)
        }

        Button("Load in Preview") {
            appState.previewPlayback.load(track)
        }

        if let cueIn = track.cuePointIn {
            Divider()
            Button("Jump to Cue In (\(cueIn.mmss()))") {
                if appState.mainPlayback.currentTrack?.id == track.id {
                    appState.mainPlayback.seek(to: cueIn)
                }
            }
            .disabled(appState.mainPlayback.currentTrack?.id != track.id)
        }

        if track.cuePointIn != nil || track.cuePointOut != nil {
            Button("Clear Cue Points") {
                track.cuePointIn = nil
                track.cuePointOut = nil
            }
        }

        Divider()
        Button("Remove from Playlist", role: .destructive) {
            appState.playlistManager.removeTrack(
                at: index,
                from: playlist,
                modelContext: modelContext
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(_ playlist: Playlist) -> some ToolbarContent {
        let isThisPerforming = appState.isPerformanceMode && appState.performingPlaylistID == playlist.id

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if isThisPerforming {
                    appState.performingPlaylistID = nil
                    appState.mode = .curation
                } else {
                    appState.mainPlayback.loadPlaylist(playlist)
                    appState.performingPlaylistID = playlist.id
                    appState.mode = .performance
                }
            } label: {
                Label(
                    isThisPerforming ? "Stop Performing" : "Perform",
                    systemImage: isThisPerforming ? "stop.circle.fill" : "play.circle.fill"
                )
            }
            .tint(isThisPerforming ? .orange : .accentColor)

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

}

// MARK: - Performance Controls (isolated observation)

/// Isolated subview that observes `mainPlayback.currentTime` for the seek slider.
/// Keeps this rapid observation out of the parent view so the List isn't disrupted.
private struct PerformanceControlsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let main = appState.mainPlayback

        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                if let track = main.currentTrack {
                    TrackInfoView(track: track, artworkSize: 40, titleFont: .headline)
                }
                Spacer()
                if let next = nextTrack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Up Next")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        TrackInfoView(track: next, artworkSize: 28, titleFont: .subheadline)
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack(spacing: 6) {
                Text(main.currentTime.mmss())
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { main.currentTime },
                        set: { main.seek(to: $0) }
                    ),
                    in: 0...max(main.duration, 0.01),
                    onEditingChanged: { editing in
                        if editing { main.beginInteractiveSeek() }
                        else { main.endInteractiveSeek() }
                    }
                )

                Text(main.duration.mmss())
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
            }

            HStack(spacing: 20) {
                Button { main.previousTrack() } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Previous Track")

                Button { main.seek(to: 0) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(main.currentTrack == nil)
                .help("Restart Track")

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

                Spacer().frame(width: 8)

                if main.isInGap {
                    Text("Next in \(String(format: "%.0f", main.gapRemaining))s")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .monospacedDigit()

                    Button("Skip") { main.nextTrack() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                } else {
                    Picker("Gap", selection: Binding(
                        get: { main.gapDuration },
                        set: { main.gapDuration = $0 }
                    )) {
                        Text("No gap").tag(0.0 as TimeInterval)
                        Text("1s").tag(1.0 as TimeInterval)
                        Text("2s").tag(2.0 as TimeInterval)
                        Text("3s").tag(3.0 as TimeInterval)
                        Text("5s").tag(5.0 as TimeInterval)
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    private var nextTrack: Track? {
        let main = appState.mainPlayback
        guard !main.playlist.isEmpty else { return nil }
        if main.currentTrack == nil { return main.playlist.first }
        let nextIndex = main.currentTrackIndex + 1
        guard nextIndex >= 0, nextIndex < main.playlist.count else { return nil }
        return main.playlist[nextIndex]
    }

}

// MARK: - Playlist Statistics Bar

private struct PlaylistStatsBar: View {
    let tracks: [Track]

    var body: some View {
        let totalDuration = tracks.reduce(0) { $0 + $1.duration }
        let bpms = tracks.compactMap(\.bpm).filter { $0 > 0 }
        let ratings = tracks.map(\.rating).filter { $0 > 0 }
        let neverPlayed = tracks.filter { $0.playCount == 0 }.count

        HStack(spacing: 16) {
            Label("\(tracks.count) tracks", systemImage: "music.note")

            Label(
                Duration.seconds(totalDuration)
                    .formatted(.time(pattern: .hourMinuteSecond)),
                systemImage: "clock"
            )

            if let minBPM = bpms.min(), let maxBPM = bpms.max() {
                let avg = bpms.reduce(0, +) / Double(bpms.count)
                if minBPM == maxBPM {
                    Label("\(Int(minBPM)) BPM (avg: \(Int(avg)))", systemImage: "metronome")
                } else {
                    Label("\(Int(minBPM))–\(Int(maxBPM)) BPM (avg: \(Int(avg)))", systemImage: "metronome")
                }
            }

            if !ratings.isEmpty {
                let avg = Double(ratings.reduce(0, +)) / Double(ratings.count)
                Label(String(format: "%.1f★", avg), systemImage: "star")
            }

            if neverPlayed > 0 {
                Label(
                    "\(neverPlayed) unplayed",
                    systemImage: "sparkles"
                )
                .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

// MARK: - Track Row (no rapidly-changing observation)

/// Row content that only observes `mainPlayback.currentTrack` (changes on track
/// transitions, not every frame). The progress bar is in a separate subview.
private struct PlaylistTrackRow: View {
    let track: Track
    let index: Int
    let isCurrentlyPlaying: Bool
    let isActivePlaylist: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
                .monospacedDigit()

            TrackArtworkView(data: track.artworkData, size: 28)

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

            Text(track.duration.mmss())
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            if track.cuePointIn != nil || track.cuePointOut != nil {
                HStack(spacing: 2) {
                    if let cueIn = track.cuePointIn {
                        Text("▶\(cueIn.mmss())")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if let cueOut = track.cuePointOut {
                        Text("◼\(cueOut.mmss())")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            } else {
                Spacer().frame(width: 80)
            }
        }
        .padding(.vertical, 2)
        .background {
            // Progress bar in isolated subview — only this re-renders on currentTime updates
            TrackProgressBackground(trackID: track.id, isActivePlaylist: isActivePlaylist)
        }
    }

}

// MARK: - Progress Background (isolated observation)

/// Sole observer of `mainPlayback.currentTime` — re-renders 20x/sec but only
/// affects this tiny background view, not the row or the List.
private struct TrackProgressBackground: View {
    let trackID: UUID
    let isActivePlaylist: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        let main = appState.mainPlayback
        let isPlaying = isActivePlaylist && main.currentTrack?.id == trackID

        if isPlaying, main.duration > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.accentColor.opacity(0.05)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: geo.size.width * max(0, min(1, main.currentTime / main.duration)))
                        .animation(.linear(duration: 0.1), value: main.currentTime)
                }
            }
        }
    }
}
