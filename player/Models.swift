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
    /// Path relative to the library folder root, e.g. "Music/Artist - Title.mp3".
    var relativePath: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: TimeInterval = 0
    var bpm: Double?
    /// User rating 0-5 (0 = unrated)
    var rating: Int = 0
    var tags: [String] = []
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

    func accessibleURL(libraryFolderURL: URL?) -> URL {
        if let folderURL = libraryFolderURL {
            return folderURL.appending(path: relativePath)
        }
        return fileURL
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
