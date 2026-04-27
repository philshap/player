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
        if let existingIndex = playlist.tracks.firstIndex(where: { $0.id == track.id }) {
            // Disallow duplicates; move existing track to the end of the playlist.
            let existingTrack = playlist.tracks.remove(at: existingIndex)
            playlist.tracks.append(existingTrack)
        } else {
            playlist.tracks.append(track)
        }
        playlist.dateModified = Date()
        notify(playlist)
    }

    func removeTrack(at index: Int, from playlist: Playlist, modelContext _: ModelContext) {
        guard index >= 0, index < playlist.tracks.count else { return }
        playlist.tracks.remove(at: index)
        playlist.dateModified = Date()
        notify(playlist)
    }

    func moveTrack(in playlist: Playlist, from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < playlist.tracks.count,
              destinationIndex >= 0, destinationIndex < playlist.tracks.count,
              sourceIndex != destinationIndex else { return }

        let track = playlist.tracks.remove(at: sourceIndex)
        playlist.tracks.insert(track, at: destinationIndex)

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
