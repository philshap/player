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

    var body: some Scene {
        // Library window — the main/default window
        Window("Library", id: "library") {
            libraryContent
                .background(WindowAutosaver(name: "player-window-library"))
        }
        .restorationBehavior(.automatic)

        // Player window — now playing + preview controls
        Window("Player", id: "player") {
            playerContent
                .background(WindowAutosaver(name: "player-window-player"))
        }
        .defaultSize(width: 500, height: 300)
        .restorationBehavior(.automatic)

        // Playlist windows — one per playlist, opened by PersistentIdentifier
        WindowGroup("Playlist", id: "playlist", for: String.self) { $playlistID in
            if let playlistID {
                playlistContent(playlistID: playlistID)
                    .background(WindowAutosaver(name: "player-window-playlist-\(playlistID)"))
            } else {
                EmptyView()
            }
        }
        .restorationBehavior(.disabled)

        .commands {
            // Window commands
            CommandGroup(after: .newItem) {
                Button("Open Library") {
                    openWindow(id: "library")
                }
                .keyboardShortcut("L", modifiers: [.command])

                Button("Open Player") {
                    openWindow(id: "player")
                }
                .keyboardShortcut("P", modifiers: [.command, .option])

                Divider()

                Button("Toggle Performance Mode") {
                    appState.mode = appState.isPerformanceMode ? .curation : .performance
                }
                .keyboardShortcut("M", modifiers: [.command, .shift])
            }

            // Playback commands — global keyboard shortcuts
            CommandMenu("Playback") {
                Button("Play / Pause") {
                    appState.mainPlayback.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Stop") {
                    appState.mainPlayback.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])

                Divider()

                Button("Next Track") {
                    appState.mainPlayback.nextTrack()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("Previous Track") {
                    appState.mainPlayback.previousTrack()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Divider()

                Button("Seek Forward 5s") {
                    appState.mainPlayback.seek(to: appState.mainPlayback.currentTime + 5)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])

                Button("Seek Back 5s") {
                    appState.mainPlayback.seek(to: appState.mainPlayback.currentTime - 5)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])

                Divider()

                // Preview controls
                Button("Preview Play / Pause") {
                    appState.previewPlayback.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [.option])

                Button("Preview Stop") {
                    appState.previewPlayback.stop()
                }
                .keyboardShortcut(".", modifiers: [.command, .option])

                Divider()

                Button("Preview Seek Forward 5s") {
                    appState.previewPlayback.seek(to: appState.previewPlayback.currentTime + 5)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.shift, .option])

                Button("Preview Seek Back 5s") {
                    appState.previewPlayback.seek(to: appState.previewPlayback.currentTime - 5)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.shift, .option])
            }
        }
    }

    @Environment(\.openWindow) private var openWindow

    // MARK: - Conditional Content

    @ViewBuilder
    private var libraryContent: some View {
        if let container = appState.modelContainer {
            LibraryView()
                .environment(appState)
                .modelContainer(container)
        } else {
            WelcomeView()
                .environment(appState)
        }
    }

    @ViewBuilder
    private var playerContent: some View {
        if let container = appState.modelContainer {
            PlayerView()
                .environment(appState)
                .modelContainer(container)
        } else {
            WelcomeView()
                .environment(appState)
        }
    }

    @ViewBuilder
    private func playlistContent(playlistID: String) -> some View {
        if let container = appState.modelContainer {
            PlaylistWindowView(playlistID: playlistID)
                .environment(appState)
                .modelContainer(container)
        }
    }
}
