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
    /// Security-scoped bookmark data — kept for migration of old-style libraries only.
    var bookmarkData: Data?
    /// Path relative to the library folder root, e.g. "Music/Artist - Title.mp3".
    /// Empty string means the track has not yet been migrated to the portable format.
    var relativePath: String = ""
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

    var bpmSortValue: Double { bpm ?? 0 }
    var lastPlayedDateSortValue: Date { lastPlayedDate ?? Date.distantPast }

    var playlists: [Playlist] = []

    init(
        relativePath: String,
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
        self.relativePath = relativePath
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

    /// Returns an accessible file URL for this track.
    ///
    /// For portable tracks (relativePath is set), resolves against the library folder URL.
    /// Falls back to the old per-file bookmark system for unmigrated tracks.
    func accessibleURL(libraryFolderURL: URL? = nil) -> URL {
        if !relativePath.isEmpty, let folderURL = libraryFolderURL {
            return folderURL.appending(path: relativePath)
        }
        // Migration fallback: resolve the per-file security-scoped bookmark
        if let resolved = resolveBookmark() {
            return resolved
        }
        return fileURL
    }

    /// Resolves the per-file security-scoped bookmark (used for unmigrated tracks only).
    private func resolveBookmark() -> URL? {
        guard let bookmarkData else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                if let newData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    self.bookmarkData = newData
                }
            }
            _ = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            print("[Track] Failed to resolve bookmark for '\(title)': \(error)")
            return nil
        }
    }
}

@Model
final class Playlist {
    var id: UUID = UUID()
    var name: String = ""
    var dateCreated: Date = Date()
    var dateModified: Date = Date()

    @Relationship(inverse: \Track.playlists)
    var tracks: [Track] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.dateCreated = Date()
        self.dateModified = Date()
    }
}
