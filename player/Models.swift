//
//  Models.swift
//  player
//

import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var fileURL: URL
    var title: String
    var artist: String
    var album: String
    var genre: String
    var duration: TimeInterval
    var bpm: Double?
    var dateAdded: Date
    var playCount: Int
    var lastPlayedDate: Date?
    var cuePointIn: TimeInterval?
    var cuePointOut: TimeInterval?

    @Relationship(inverse: \PlaylistEntry.track)
    var playlistEntries: [PlaylistEntry] = []

    init(
        fileURL: URL,
        title: String,
        artist: String = "",
        album: String = "",
        genre: String = "",
        duration: TimeInterval = 0,
        bpm: Double? = nil,
        cuePointIn: TimeInterval? = nil,
        cuePointOut: TimeInterval? = nil
    ) {
        self.id = UUID()
        self.fileURL = fileURL
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.duration = duration
        self.bpm = bpm
        self.dateAdded = Date()
        self.playCount = 0
        self.lastPlayedDate = nil
        self.cuePointIn = cuePointIn
        self.cuePointOut = cuePointOut
    }
}

@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var dateCreated: Date
    var dateModified: Date

    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.playlist)
    var entries: [PlaylistEntry] = []

    /// Returns tracks ordered by sortOrder.
    var orderedTracks: [Track] {
        entries.sorted { $0.sortOrder < $1.sortOrder }.map(\.track)
    }

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.dateCreated = Date()
        self.dateModified = Date()
    }
}

@Model
final class PlaylistEntry {
    @Attribute(.unique) var id: UUID
    var sortOrder: Int
    var track: Track
    var playlist: Playlist

    init(track: Track, playlist: Playlist, sortOrder: Int) {
        self.id = UUID()
        self.track = track
        self.playlist = playlist
        self.sortOrder = sortOrder
    }
}
