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
    var mode: AppMode = .curation {
        didSet { mainPlayback.recordsPlayStats = (mode == .performance) }
    }

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

    /// The iTunes Media folder URL for Apple Music drag imports (security-scoped access is active).
    private(set) var itunesMediaFolderURL: URL?

    /// Controls the welcome/onboarding sheet visibility.
    var showWelcomeSheet: Bool = false

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
        resolveItunesMediaFolder()
    }

    // MARK: - Library Resolution

    private func resolveExistingLibrary() {
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

    // MARK: - iTunes Media Access

    func grantItunesMediaAccess(at url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "itunesMediaFolderBookmark")
        }
        itunesMediaFolderURL = url
    }

    private func resolveItunesMediaFolder() {
        guard let data = UserDefaults.standard.data(forKey: "itunesMediaFolderBookmark") else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) else { return }
        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(refreshed, forKey: "itunesMediaFolderBookmark")
        }
        _ = url.startAccessingSecurityScopedResource()
        itunesMediaFolderURL = url
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
        let schema = Schema([Track.self, Playlist.self])
        let storeURL = folderURL.appending(path: "library.sqlite")
        let config = ModelConfiguration(url: storeURL)

        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("[AppState] ModelContainer creation failed: \(error)")
            throw error
        }

        self.modelContainer = container
        self.libraryFolderURL = folderURL
        self.showWelcomeSheet = false
    }
}
