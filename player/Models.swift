//
//  Models.swift
//  player
//

import Foundation
import SwiftData

@Model
final class Track {
    var id: UUID = UUID()
    var fileURL: URL
    /// Security-scoped bookmark data for re-accessing the file after app relaunch.
    var bookmarkData: Data?
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: TimeInterval = 0
    var bpm: Double?
    /// User rating 0-5 (0 = unrated)
    var rating: Int = 0
    var dateAdded: Date = Date()
    var playCount: Int = 0
    var lastPlayedDate: Date?
    var cuePointIn: TimeInterval?
    var cuePointOut: TimeInterval?

    /// Album artwork image data (JPEG/PNG). Stored externally by SwiftData.
    @Attribute(.externalStorage)
    var artworkData: Data?

    var bpmSortValue: Double { bpm ?? 0}
    var lastPlayedDateSortValue: Date { lastPlayedDate ?? Date.distantPast }

    @Relationship(inverse: \PlaylistEntry.track)
    var playlistEntries: [PlaylistEntry] = []

    init(
        fileURL: URL,
        bookmarkData: Data? = nil,
        title: String,
        artist: String = "",
        album: String = "",
        duration: TimeInterval = 0,
        bpm: Double? = nil,
        rating: Int = 0,
        cuePointIn: TimeInterval? = nil,
        cuePointOut: TimeInterval? = nil
    ) {
        self.id = UUID()
        self.fileURL = fileURL
        self.bookmarkData = bookmarkData
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.bpm = bpm
        self.rating = rating
        self.dateAdded = Date()
        self.playCount = 0
        self.lastPlayedDate = nil
        self.cuePointIn = cuePointIn
        self.cuePointOut = cuePointOut
    }

    /// Resolves the security-scoped bookmark and starts access.
    /// Returns the accessible URL. Caller must call `stopAccessingSecurityScopedResource()` when done.
    func resolveBookmark() -> URL? {
        guard let bookmarkData else {
            print("[Track] No bookmark data for: \(title)")
            return nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                print("[Track] Bookmark is stale for: \(title), refreshing...")
                if let newData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    self.bookmarkData = newData
                }
            }

            let didStart = url.startAccessingSecurityScopedResource()
            print("[Track] resolveBookmark for '\(title)': url=\(url.path), didStartAccess=\(didStart), isStale=\(isStale)")
            return url
        } catch {
            print("[Track] Failed to resolve bookmark for '\(title)': \(error)")
            return nil
        }
    }

    /// Returns an accessible file URL — tries bookmark first, falls back to raw fileURL.
    func accessibleURL() -> URL {
        if let resolved = resolveBookmark() {
            return resolved
        }
        print("[Track] Falling back to raw fileURL for '\(title)': \(fileURL.path)")
        return fileURL
    }
}

@Model
final class Playlist {
    var id: UUID = UUID()
    var name: String = ""
    var dateCreated: Date = Date()
    var dateModified: Date = Date()

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
    var id: UUID = UUID()
    var sortOrder: Int = 0
    var track: Track
    var playlist: Playlist

    init(track: Track, playlist: Playlist, sortOrder: Int) {
        self.id = UUID()
        self.track = track
        self.playlist = playlist
        self.sortOrder = sortOrder
    }
}
