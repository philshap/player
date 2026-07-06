//
//  PlaylistWindowView.swift
//  player
//

import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers

struct PlaylistWindowView: View {
    let playlistID: String
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]

    @Environment(\.dismiss) private var dismiss

    @Query private var allLibraryTracks: [Track]

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showDeleteConfirmation = false
    @State private var showStopConfirmation = false
    @State private var selectedTrackID: Track.ID?
    @State private var showBPMGraph = false

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
        .onAppear {
            // If the playlist was deleted while the app was closed, the system
            // will still try to restore its window (restorationBehavior: .automatic),
            // but @Query will find nothing. onChange(of: playlist == nil) only fires
            // on transitions, so we need onAppear to catch the nil-from-birth case.
            if playlist == nil { dismiss() }
        }
        .onChange(of: playlist == nil) {
            if playlist == nil { dismiss() }
        }
    }

    // MARK: - Playlist Content

    @ViewBuilder
    private func playlistContent(_ playlist: Playlist) -> some View {
        let tracks = playlist.orderedTracks

        NavigationStack {
            ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                if !tracks.isEmpty {
                    let isActivePlaylist = appState.isPerformanceMode && appState.performingPlaylistID == playlist.id
                    BPMGraphSection(
                        tracks: tracks,
                        isExpanded: $showBPMGraph,
                        currentTrackID: isActivePlaylist ? appState.mainPlayback.currentTrack?.id : nil,
                        onSelectTrack: { trackID in
                            selectedTrackID = trackID
                            withAnimation {
                                scrollProxy.scrollTo(trackID, anchor: .center)
                            }
                        }
                    )
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
                            let allTracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
                            let droppedTracks = TrackTransfer.tracks(from: droppedStrings, in: allTracks)
                            appState.playlistManager.addTracks(droppedTracks, to: playlist, modelContext: modelContext)
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
        }
        .focusedValue(\.focusedPlaylist, playlist)
        .focusedValue(\.playlistImportHandler, { [allLibraryTracks, modelContext] exportData in
            let (_, unmatchedCount) = PlaylistIO.importPlaylist(
                from: exportData,
                libraryTracks: allLibraryTracks,
                modelContext: modelContext,
                playlistManager: appState.playlistManager
            )
            if unmatchedCount > 0 {
                let alert = NSAlert()
                alert.messageText = "Playlist Imported with Gaps"
                alert.informativeText = "\(unmatchedCount) track\(unmatchedCount == 1 ? "" : "s") could not be found in your library and were skipped."
                alert.alertStyle = .informational
                alert.runModal()
            }
        })
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
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \"\(playlist.name)\"? This cannot be undone.")
        }
        .confirmationDialog(
            "Stop Performing",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Performing", role: .destructive) {
                appState.performingPlaylistID = nil
                appState.mode = .curation
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stop performing \"\(playlist.name)\"? This will stop playback.")
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
                    .id(track.id)
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
                    let allTracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
                    let droppedTracks = TrackTransfer.tracks(from: [string], in: allTracks)
                    appState.playlistManager.insertTracks(droppedTracks, at: index, into: playlist)
                }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func trackContextMenu(index: Int, track: Track, tracks: [Track], playlist: Playlist) -> some View {
        if !appState.isPerformanceMode {
            Button("Play from Here") {
                appState.mainPlayback.loadPlaylist(playlist)
                appState.mainPlayback.play(from: index)
            }
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
                    showStopConfirmation = true
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
            .disabled(!isThisPerforming && appState.isPerformanceMode)

            if !appState.isPerformanceMode {
                Button {
                    renameText = playlist.name
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    if playlist.orderedTracks.isEmpty {
                        appState.playlistManager.deletePlaylist(playlist, modelContext: modelContext)
                        dismiss()
                    } else {
                        showDeleteConfirmation = true
                    }
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

// MARK: - BPM Graph Section

/// Collapsible BPM-over-set-position chart shown above the track list.
/// Dashed guide lines at 110 and 180 BPM bracket the typical 120–175 range.
private struct BPMGraphSection: View {
    let tracks: [Track]
    @Binding var isExpanded: Bool
    let currentTrackID: UUID?
    let onSelectTrack: (UUID) -> Void

    @State private var hoveredIndex: Int?

    private var points: [(index: Int, track: Track, bpm: Double)] {
        tracks.enumerated().compactMap { index, track in
            guard let bpm = track.bpm, bpm > 0 else { return nil }
            return (index, track, bpm)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Label("BPM", systemImage: "metronome")
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            if isExpanded {
                if points.isEmpty {
                    Text("No BPM data in this playlist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)
                } else {
                    chart
                        .frame(height: 130)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var chart: some View {
        let points = self.points
        let bpms = points.map(\.bpm)
        let yMin = min(100, (bpms.min() ?? 110) - 10)
        let yMax = max(190, (bpms.max() ?? 180) + 10)

        return Chart {
            RuleMark(y: .value("BPM", 110))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("BPM", 180))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            ForEach(points, id: \.track.id) { point in
                LineMark(
                    x: .value("Track", point.index + 1),
                    y: .value("BPM", point.bpm)
                )
                .foregroundStyle(Color.accentColor.opacity(0.6))
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("Track", point.index + 1),
                    y: .value("BPM", point.bpm)
                )
                .foregroundStyle(point.track.id == currentTrackID ? Color.orange : Color.accentColor)
                .symbolSize(point.track.id == currentTrackID ? 90 : (point.index == hoveredIndex ? 80 : 40))
                .annotation(
                    position: .top,
                    spacing: 6,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    if point.index == hoveredIndex {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(point.track.title)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(Int(point.bpm.rounded())) BPM")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(radius: 2)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredIndex = nearestPoint(atX: location.x, proxy: proxy)?.index
                        case .ended:
                            hoveredIndex = nil
                        }
                    }
                    .onTapGesture { location in
                        if let point = nearestPoint(atX: location.x, proxy: proxy) {
                            onSelectTrack(point.track.id)
                        }
                    }
            }
        }
        .chartXScale(domain: 0.5...(Double(tracks.count) + 0.5))
        .chartYScale(domain: yMin...yMax)
        .chartYAxis {
            AxisMarks(values: [110, 180]) { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(tracks.count, 12))) { value in
                if let n = value.as(Int.self), n >= 1, n <= tracks.count {
                    AxisValueLabel {
                        Text("\(n)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Maps a plot-area x position to the nearest charted track.
    private func nearestPoint(atX x: CGFloat, proxy: ChartProxy) -> (index: Int, track: Track, bpm: Double)? {
        guard let xValue: Double = proxy.value(atX: x) else { return nil }
        return points.min {
            abs(Double($0.index + 1) - xValue) < abs(Double($1.index + 1) - xValue)
        }
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

                if !track.tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(track.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                .lineLimit(1)
                        }
                    }
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
