# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

This is an Xcode project. All commands should be run from the `player/` directory (which contains `player.xcodeproj`).

```bash
# Build (simulator)
xcodebuild -project player.xcodeproj -scheme player -destination 'platform=macOS' build

# Run all tests
xcodebuild test -project player.xcodeproj -scheme player -destination 'platform=macOS'

# Run a single test class
xcodebuild test -project player.xcodeproj -scheme player -destination 'platform=macOS' -only-testing:playerTests/AudioEngineChannelIsolationTests
```

Open `player.xcodeproj` in Xcode for interactive development and UI work.

## Architecture

### State & Dependency Flow

`AppState` is the root object, created once in `playerApp.swift` and injected via `.environment(appState)`. It owns all shared services:
- `AudioEngineManager` — the AVAudioEngine host
- `MainPlaybackController` — playlist/main-output playback (left channel)
- `PreviewPlaybackController` — cue/preview playback (right channel)
- `LibraryManager` — file import and metadata
- `PlaylistManager` — playlist CRUD and track ordering

The SwiftData `ModelContainer` and `libraryFolderURL` live in `AppState` and are only valid after the user opens a library. Views guard on `appState.isLibraryReady` before showing content.

### Playback Class Hierarchy

```
PlaybackController          (base: single-track buffer playback, seek, position timer)
├── MainPlaybackController  (adds: playlist, prefetch, inter-track gap, play counts)
└── PreviewPlaybackController (adds: bypassCuePoints, unload())
```

`PlaybackController` is not abstract — the base `onTrackCompletion`, `willStartTrack`, and `didStartTrack` hooks provide default behavior that subclasses override.

### Audio Engine & Channel Isolation

`AudioEngineManager` hosts a single `AVAudioEngine`. Each `PlaybackController` owns its own `AVAudioPlayerNode` + `AVAudioMixerNode` (player → mixer → mainMixerNode).

Channel isolation is enforced **in the buffer content, not via pan**. Every audio file is decoded to mono (multi-channel averaged), then packed into a stereo `AVAudioPCMBuffer` with signal in only one channel:
- Main output → left channel only
- Preview output → right channel only
- "Both" routing → signal in both channels

`AVAudioMixerNode.pan` is intentionally not used — it is unreliable across hardware configurations and macOS versions.

All player-node operations (stop, play, scheduleBuffer) are dispatched to a serial `DispatchQueue` (`audioEngine.playerQueue`) to avoid priority inversion when called from the main actor.

### Generation Counter Pattern

Every `PlaybackController` has an `Int` property `playbackGeneration` that increments on every play, seek, and stop. Async callbacks (buffer load completions, AVAudioPlayerNode completion handlers) capture the generation at dispatch time and are no-ops if `self.playbackGeneration != capturedGeneration` when they fire. This prevents stale completions from corrupting state during rapid navigation.

### Pre-fetch

When a track starts playing, `MainPlaybackController.didStartTrack` immediately kicks off `prefetchNext(index:generation:)` on a background Task. Once the next track's buffer is loaded it is stored in `preloadedBuffer`. When auto-advance fires, `playTrack(at:)` claims the buffer and schedules it directly — no disk read at the track boundary.

If a gap is configured (`gapDuration > 0`), a repeating `Timer` handles the countdown before advancing.

### Portable Library

The library is a self-contained folder (`library.sqlite` + `Music/` subfolder). `AppState` stores a single folder-level security-scoped bookmark in `UserDefaults` (`"libraryFolderBookmark"`). Tracks store `relativePath` (e.g. `"Music/Artist - Title.mp3"`) and resolve their file URL at runtime via `Track.accessibleURL(libraryFolderURL:)`.

Old-style libraries (absolute paths + per-file bookmarks, pre-portable) are detected by the presence of the default SwiftData store and can be migrated via `AppState.migrateOldLibrary(to:)`.

### Playlist Change Observation

`PlaylistManager` posts `.playlistDidChange` notifications (with `playlistID` in userInfo) whenever a playlist is mutated. `MainPlaybackController` observes these to keep its in-memory `[Track]` array in sync with the SwiftData model and to invalidate/restart prefetch when the playlist is reordered while playing.

### Multi-Window Layout

The app uses three window types (defined in `playerApp.swift`):
- `Window("Library", id: "library")` — `LibraryView`
- `Window("Player", id: "player")` — `PlayerView`
- `WindowGroup("Playlist", id: "playlist", for: String.self)` — `PlaylistWindowView`, one per playlist

Global keyboard shortcuts are registered via `CommandMenu("Playback")` in the scene's `.commands` modifier.
