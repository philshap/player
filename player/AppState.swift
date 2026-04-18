//
//  AppState.swift
//  player
//

import Foundation
import Observation
import SwiftData

enum AppMode: String, CaseIterable {
    case curation
    case performance
}

/// Centralized app state holding shared services, library folder management, and mode.
@Observable
final class AppState {
    var mode: AppMode = .curation

    /// The ID of the playlist currently loaded for performance playback.
    var performingPlaylistID: UUID? = nil

    let audioEngine: AudioEngineManager
    let mainPlayback: MainPlaybackController
    let previewPlayback: PreviewPlaybackController
    let libraryManager: LibraryManager
    let playlistManager: PlaylistManager

    var isPerformanceMode: Bool { mode == .performance }

    // MARK: - Library Folder State

    /// The currently open library folder URL (security-scoped access is active).
    private(set) var libraryFolderURL: URL? {
        didSet {
            mainPlayback.libraryFolderURL = libraryFolderURL
            previewPlayback.libraryFolderURL = libraryFolderURL
            libraryManager.libraryFolderURL = libraryFolderURL
        }
    }

    /// The SwiftData container for the currently open library.
    private(set) var modelContainer: ModelContainer?

    /// Whether the library is open and ready to use.
    var isLibraryReady: Bool { modelContainer != nil && libraryFolderURL != nil }

    /// Controls the welcome/onboarding sheet visibility.
    var showWelcomeSheet: Bool = false

    /// True when an old-style library store exists (pre-portable-feature) and hasn't been migrated.
    private(set) var hasOldLibrary: Bool = false

    /// The URL of the old default SwiftData store (used for migration).
    private(set) var oldStoreURL: URL? = nil

    // MARK: - Init

    init() {
        let engine = AudioEngineManager()
        self.audioEngine = engine
        self.mainPlayback = MainPlaybackController(audioEngine: engine)
        self.previewPlayback = PreviewPlaybackController(audioEngine: engine)
        self.libraryManager = LibraryManager()
        self.playlistManager = PlaylistManager()

        try? engine.start()

        resolveExistingLibrary()
    }

    // MARK: - Library Resolution

    private func resolveExistingLibrary() {
        // Check for old default store from pre-portable-feature installs
        let legacyConfig = ModelConfiguration("player", isStoredInMemoryOnly: false)
        if FileManager.default.fileExists(atPath: legacyConfig.url.path) {
            oldStoreURL = legacyConfig.url
            hasOldLibrary = true
        }

        guard let bookmarkData = UserDefaults.standard.data(forKey: "libraryFolderBookmark") else {
            showWelcomeSheet = true
            return
        }

        var isStale = false
        do {
            let folderURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                if let refreshed = try? folderURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(refreshed, forKey: "libraryFolderBookmark")
                }
            }

            let didAccess = folderURL.startAccessingSecurityScopedResource()
            print("[AppState] Resolved library folder: \(folderURL.path), access=\(didAccess)")

            try loadLibrary(at: folderURL)
        } catch {
            print("[AppState] Failed to resolve library bookmark: \(error)")
            showWelcomeSheet = true
        }
    }

    // MARK: - Public Library Operations

    /// Creates a new portable library at the given folder URL.
    func createNewLibrary(at folderURL: URL) throws {
        let _ = folderURL.startAccessingSecurityScopedResource()

        // Create Music subfolder
        let musicFolder = folderURL.appending(path: "Music")
        try FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)

        try storeBookmark(for: folderURL)
        try loadLibrary(at: folderURL)
    }

    /// Opens an existing portable library at the given folder URL.
    func openExistingLibrary(at folderURL: URL) throws {
        let _ = folderURL.startAccessingSecurityScopedResource()
        try storeBookmark(for: folderURL)
        try loadLibrary(at: folderURL)
    }

    // MARK: - Migration

    /// Migrates an old-style library (absolute paths + per-file bookmarks, default SwiftData store)
    /// to a new portable library folder. Copies all reachable audio files into `Music/`,
    /// recreates track records with relative paths, and saves the new store at the destination.
    func migrateOldLibrary(to newFolderURL: URL) async throws {
        guard let storeURL = oldStoreURL else { return }

        let _ = newFolderURL.startAccessingSecurityScopedResource()

        // Open the old store read-only to extract track data
        let schema = Schema([Track.self, Playlist.self, PlaylistEntry.self])
        let oldConfig = ModelConfiguration(url: storeURL)
        let oldContainer = try ModelContainer(for: schema, configurations: [oldConfig])
        let oldContext = ModelContext(oldContainer)

        let allTracks = try oldContext.fetch(FetchDescriptor<Track>())
        let allPlaylists = try oldContext.fetch(FetchDescriptor<Playlist>())

        // Prepare destination
        let musicFolder = newFolderURL.appending(path: "Music")
        try FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)

        // Copy files and collect mapping: old track ID → new relative path
        var relativePathByID: [UUID: String] = [:]
        for track in allTracks {
            let sourceURL = track.accessibleURL()
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                print("[Migration] File not found, skipping: \(track.title)")
                continue
            }
            let destURL = uniqueDestinationURL(in: musicFolder, for: sourceURL)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                relativePathByID[track.id] = "Music/\(destURL.lastPathComponent)"
            } catch {
                print("[Migration] Failed to copy \(track.title): \(error)")
            }
        }

        // Create new store
        let newStoreURL = newFolderURL.appending(path: "library.sqlite")
        let newConfig = ModelConfiguration(url: newStoreURL)
        let newContainer = try ModelContainer(for: schema, configurations: [newConfig])
        let newContext = ModelContext(newContainer)

        // Re-create tracks in new store
        var newTrackByOldID: [UUID: Track] = [:]
        for track in allTracks {
            guard let relativePath = relativePathByID[track.id] else { continue }
            let newTrack = Track(
                relativePath: relativePath,
                fileURL: newFolderURL.appending(path: relativePath),
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                bpm: track.bpm,
                rating: track.rating,
                cuePointIn: track.cuePointIn,
                cuePointOut: track.cuePointOut
            )
            newTrack.artworkData = track.artworkData
            newTrack.playCount = track.playCount
            newTrack.lastPlayedDate = track.lastPlayedDate
            newTrack.dateAdded = track.dateAdded
            newContext.insert(newTrack)
            newTrackByOldID[track.id] = newTrack
        }

        // Re-create playlists and entries
        for playlist in allPlaylists {
            let newPlaylist = Playlist(name: playlist.name)
            newPlaylist.dateCreated = playlist.dateCreated
            newContext.insert(newPlaylist)
            for entry in playlist.entries.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                guard let newTrack = newTrackByOldID[entry.track.id] else { continue }
                let newEntry = PlaylistEntry(track: newTrack, playlist: newPlaylist, sortOrder: entry.sortOrder)
                newContext.insert(newEntry)
            }
        }

        try newContext.save()

        // Switch to new library
        try storeBookmark(for: newFolderURL)
        self.modelContainer = newContainer
        self.libraryFolderURL = newFolderURL
        self.showWelcomeSheet = false
        self.hasOldLibrary = false
    }

    /// Returns a URL in `folder` that doesn't conflict with existing files.
    private func uniqueDestinationURL(in folder: URL, for sourceURL: URL) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var candidate = folder.appending(path: sourceURL.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Private Helpers

    private func storeBookmark(for folderURL: URL) throws {
        let bookmark = try folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: "libraryFolderBookmark")
    }

    private func loadLibrary(at folderURL: URL) throws {
        let schema = Schema([Track.self, Playlist.self, PlaylistEntry.self])
        let storeURL = folderURL.appending(path: "library.sqlite")
        let config = ModelConfiguration(url: storeURL)

        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Migration failed — delete the store and retry with a fresh one
            print("[AppState] ModelContainer creation failed, resetting store: \(error)")
            let related = [storeURL,
                           storeURL.appendingPathExtension("wal"),
                           storeURL.appendingPathExtension("shm")]
            for url in related { try? FileManager.default.removeItem(at: url) }
            container = try ModelContainer(for: schema, configurations: [config])
        }

        self.modelContainer = container
        self.libraryFolderURL = folderURL
        self.showWelcomeSheet = false
    }
}
