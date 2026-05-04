//
//  PlaylistManager.swift
//  player
//

import Foundation
import SwiftData

extension Notification.Name {
    static let playlistDidChange = Notification.Name("PlayerPlaylistDidChange")
}

@Observable
final class PlaylistManager {

    // MARK: - Playlist CRUD

    func uniquePlaylistName(base: String, among playlists: [Playlist]) -> String {
        let names = Set(playlists.map(\.name))
        if !names.contains(base) { return base }
        var counter = 1
        while names.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    /// Creates a uniquely named playlist, fetching existing names from the model context.
    @discardableResult
    func createNewPlaylist(modelContext: ModelContext) -> Playlist {
        let existing = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        let name = uniquePlaylistName(base: "New Playlist", among: existing)
        return createPlaylist(name: name, modelContext: modelContext)
    }

    @discardableResult
    func createPlaylist(name: String, modelContext: ModelContext) -> Playlist {
        let playlist = Playlist(name: name)
        modelContext.insert(playlist)
        return playlist
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) {
        playlist.name = name
        playlist.dateModified = Date()
    }

    func deletePlaylist(_ playlist: Playlist, modelContext: ModelContext) {
        modelContext.delete(playlist)
    }

    // MARK: - Track Management

    func addTrack(_ track: Track, to playlist: Playlist, modelContext _: ModelContext) {
        ensureTrackOrder(playlist)
        if !playlist.tracks.contains(where: { $0.id == track.id }) {
            playlist.tracks.append(track)
        }
        playlist.trackOrder.removeAll { $0 == track.id }
        playlist.trackOrder.append(track.id)
        playlist.dateModified = Date()
        notify(playlist)
    }

    func addTracks(_ tracks: [Track], to playlist: Playlist, modelContext _: ModelContext) {
        guard !tracks.isEmpty else { return }
        ensureTrackOrder(playlist)
        for track in tracks {
            if !playlist.tracks.contains(where: { $0.id == track.id }) {
                playlist.tracks.append(track)
            }
            playlist.trackOrder.removeAll { $0 == track.id }
            playlist.trackOrder.append(track.id)
        }
        playlist.dateModified = Date()
        notify(playlist)
    }

    /// Inserts tracks at a specific index, handling duplicates by moving them to the target position.
    /// Fires a single notification after all tracks are placed.
    func insertTracks(_ tracks: [Track], at index: Int, into playlist: Playlist) {
        guard !tracks.isEmpty else { return }
        ensureTrackOrder(playlist)
        var order = playlist.trackOrder
        var cursor = min(index, order.count)
        for track in tracks {
            if !playlist.tracks.contains(where: { $0.id == track.id }) {
                playlist.tracks.append(track)
            }
            if let existingIndex = order.firstIndex(of: track.id) {
                order.remove(at: existingIndex)
                let adjustedCursor = existingIndex < cursor ? cursor - 1 : cursor
                let clampedCursor = min(adjustedCursor, order.count)
                order.insert(track.id, at: clampedCursor)
                cursor = clampedCursor + 1
            } else {
                let clampedCursor = min(cursor, order.count)
                order.insert(track.id, at: clampedCursor)
                cursor = clampedCursor + 1
            }
        }
        playlist.trackOrder = order
        playlist.dateModified = Date()
        notify(playlist)
    }

    func removeTrack(at index: Int, from playlist: Playlist, modelContext _: ModelContext) {
        ensureTrackOrder(playlist)
        guard index >= 0, index < playlist.trackOrder.count else { return }
        let id = playlist.trackOrder[index]
        playlist.trackOrder.remove(at: index)
        playlist.tracks.removeAll { $0.id == id }
        playlist.dateModified = Date()
        notify(playlist)
    }

    func moveTrack(in playlist: Playlist, from sourceIndex: Int, to destinationIndex: Int) {
        ensureTrackOrder(playlist)
        guard sourceIndex >= 0, sourceIndex < playlist.trackOrder.count,
              destinationIndex >= 0, destinationIndex < playlist.trackOrder.count,
              sourceIndex != destinationIndex else { return }
        playlist.trackOrder.insert(playlist.trackOrder.remove(at: sourceIndex), at: destinationIndex)
        playlist.dateModified = Date()
        notify(playlist)
    }

    /// Bootstraps trackOrder from the tracks relationship on first mutation after upgrade.
    private func ensureTrackOrder(_ playlist: Playlist) {
        guard playlist.trackOrder.isEmpty, !playlist.tracks.isEmpty else { return }
        playlist.trackOrder = playlist.tracks.map(\.id)
    }

    private func notify(_ playlist: Playlist) {
        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["playlistID": playlist.id]
        )
    }
}
