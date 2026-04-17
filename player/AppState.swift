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

/// Centralized app state holding shared services and mode.
@Observable
final class AppState {
    var mode: AppMode = .curation

    let audioEngine: AudioEngineManager
    let mainPlayback: MainPlaybackController
    let previewPlayback: PreviewPlaybackController
    let libraryManager: LibraryManager
    let playlistManager: PlaylistManager

    var isPerformanceMode: Bool { mode == .performance }

    init() {
        let engine = AudioEngineManager()
        self.audioEngine = engine
        self.mainPlayback = MainPlaybackController(audioEngine: engine)
        self.previewPlayback = PreviewPlaybackController(audioEngine: engine)
        self.libraryManager = LibraryManager()
        self.playlistManager = PlaylistManager()

        try? engine.start()
    }
}
