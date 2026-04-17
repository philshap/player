//
//  playerApp.swift
//  player
//
//  Created by Phil Shapiro on 4/7/26.
//

import SwiftData
import SwiftUI

@main
struct playerApp: App {
    @State private var appState = AppState()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Track.self,
            Playlist.self,
            PlaylistEntry.self
        ])
        let configuration = ModelConfiguration("player", isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        // Library window — the main/default window
        Window("Library", id: "library") {
            LibraryView()
                .environment(appState)
        }
        .modelContainer(sharedModelContainer)

        // Player window — now playing + preview controls
        Window("Player", id: "player") {
            PlayerView()
                .environment(appState)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 500, height: 300)

        // Playlist windows — one per playlist, opened by PersistentIdentifier
        WindowGroup("Playlist", id: "playlist", for: String.self) { $playlistID in
            PlaylistWindowView(playlistID: playlistID)
                .environment(appState)
        }
        .modelContainer(sharedModelContainer)

        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Library") {
                    openLibrary()
                }
                .keyboardShortcut("L", modifiers: [.command])

                Button("Open Player") {
                    openPlayer()
                }
                .keyboardShortcut("P", modifiers: [.command])

                Divider()

                Button("Toggle Performance Mode") {
                    appState.mode = appState.isPerformanceMode ? .curation : .performance
                }
                .keyboardShortcut("M", modifiers: [.command, .shift])
            }
        }
    }

    @Environment(\.openWindow) private var openWindow

    private func openLibrary() {
        openWindow(id: "library")
    }

    private func openPlayer() {
        openWindow(id: "player")
    }
}
