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

    func addTrack(_ track: Track, to playlist: Playlist, modelContext: ModelContext) {
        let nextSortOrder = playlist.entries.count
        if let existingIndex = playlist.entries.firstIndex(where: { $0.track.id == track.id }) {
            // Disallow duplicate entries; move existing entry to the end of the playlist.
            let entry = playlist.entries[existingIndex]
            entry.sortOrder = nextSortOrder
        } else {
            modelContext.insert(PlaylistEntry(track: track, playlist: playlist, sortOrder: nextSortOrder))
        }
        playlist.dateModified = Date()
        notify(playlist)
    }

    func removeTrack(at index: Int, from playlist: Playlist, modelContext: ModelContext) {
        let sorted = playlist.entries.sorted { $0.sortOrder < $1.sortOrder }
        guard index >= 0, index < sorted.count else { return }

        let entryToRemove = sorted[index]
        modelContext.delete(entryToRemove)

        // Re-normalize sortOrder for remaining entries
        let remaining = sorted.filter { $0.id != entryToRemove.id }
        for (newOrder, entry) in remaining.enumerated() {
            entry.sortOrder = newOrder
        }

        playlist.dateModified = Date()
        notify(playlist)
    }

    func moveTrack(in playlist: Playlist, from sourceIndex: Int, to destinationIndex: Int) {
        var sorted = playlist.entries.sorted { $0.sortOrder < $1.sortOrder }
        guard sourceIndex >= 0, sourceIndex < sorted.count,
              destinationIndex >= 0, destinationIndex < sorted.count,
              sourceIndex != destinationIndex else { return }

        let entry = sorted.remove(at: sourceIndex)
        sorted.insert(entry, at: destinationIndex)

        for (newOrder, entry) in sorted.enumerated() {
            entry.sortOrder = newOrder
        }

        playlist.dateModified = Date()
        notify(playlist)
    }

    private func notify(_ playlist: Playlist) {
        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["playlistID": playlist.id]
        )
    }
}
