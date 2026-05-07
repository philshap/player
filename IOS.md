# iOS Support

## Concept

Initial iOS support would be a performance-focused iPad app.

### UI

The main playback screen is a single window with three tiled views:
- The top half of the screen is the library view
- The lower left quarter is the player view
- The lower right quarter is the active playlist

The library view can show a playlist instead of the full library (or a playlist filters the library to only its tracks).

The UI supports dragging tracks using iOS gestures, mirroring mouse drag support on Mac. Commands currently only accessible via menus (e.g. Remove from Playlist) will need icon affordances in the iOS UI.

### Storage (Option A — iOS Files App)

The library folder structure (`library.sqlite` + `Music/` subfolder) stays identical to macOS. The user places their library in the app's Documents directory or iCloud Drive via the Files app, AirDrop, or desktop sync.

On first launch the user picks their library folder once using `.fileImporter`. iOS returns a security-scoped URL that is bookmarked exactly as on macOS — the `relativePath` resolution in `Track.accessibleURL` requires no changes.

Users who want Mac↔iPad sync can point both at the same iCloud Drive folder. A future enhancement could add explicit iCloud container support.

### Code Organization (Option 3 — Local Swift Package + Two Targets)

Shared core logic lives in a local Swift Package (`PlayerCore`). Platform-specific code (UI, file pickers, image handling) stays in separate macOS and iOS app targets. The compiler enforces the boundary — AppKit types cannot compile into `PlayerCore`.

---

## Implementation Plan

### Phase 1 — Extract PlayerCore Package

Create a local Swift Package containing all platform-agnostic code. This establishes the clean boundary before any iOS-specific work begins.

**Tasks**

- [ ] Create `PlayerCore` local Swift Package in the workspace (File → New → Package)
- [ ] Move `AudioEngineManager.swift` into PlayerCore
- [ ] Move `PlaybackController.swift` into PlayerCore
- [ ] Move `MainPlaybackController.swift` into PlayerCore
- [ ] Move `PreviewPlaybackController.swift` into PlayerCore
- [ ] Move `PlaylistManager.swift` into PlayerCore
- [ ] Move `Models.swift` into PlayerCore
- [ ] Move `TrackTransfer.swift` into PlayerCore
- [ ] Move shared `LibraryManager` logic into PlayerCore (strip AppKit image code and ITLibrary — leave stubs)
- [ ] Move `PlaylistIO.swift` into PlayerCore
- [ ] Move `Utilities.swift` into PlayerCore (audit for AppKit use first)
- [ ] Add `PlayerCore` as a dependency of the existing macOS app target
- [ ] Verify macOS app builds and all tests pass

### Phase 2 — Isolate macOS-Specific Code

Separate the remaining macOS-only code so the iOS target can be added cleanly.

**Tasks**

- [ ] Create `LibraryManager+macOS.swift` in the macOS target for NSImage resizing, ITLibrary import, and file trash
- [ ] Create `LibraryManager+iOS.swift` stub in preparation for iOS implementation
- [ ] Replace AppKit image resizing in `PlayerView.swift` dominant-color extraction with a `#if` split or platform file (NSImage → UIImage)
- [ ] Audit `Utilities.swift` for any AppKit use; split if needed
- [ ] Verify macOS app builds and tests pass with the split in place

### Phase 3 — Add iOS App Target

Add the iPad target and wire up `PlayerCore`.

**Tasks**

- [ ] Add new iOS app target (`player-ios`) to the Xcode project
- [ ] Add `PlayerCore` package as a dependency of the iOS target
- [ ] Configure iOS target: deployment target, bundle ID, entitlements, Info.plist
- [ ] Add app icon and launch screen assets for iOS
- [ ] Implement `playerApp.swift` for iOS (single `WindowGroup`, no `.commands`)
- [ ] Implement `AppState+iOS.swift`: replace `NSOpenPanel`/iTunes bookmark setup with `.fileImporter`-based library folder selection
- [ ] Implement `LibraryManager+iOS.swift`: UIImage-based artwork resizing, no ITLibrary
- [ ] Confirm iOS target builds (UI stubs acceptable at this stage)

### Phase 4 — iOS UI Implementation

Build the iPad UI using the tiled single-window layout.

**Tasks**

- [ ] Implement `RootView` (iPad): top-half library, bottom-left player, bottom-right playlist using `HSplitView`/`VSplitView` or `GeometryReader`
- [ ] Implement `LibraryView+iOS.swift`: `List`-based track browser replacing `Table`; column-sort via toolbar menu
- [ ] Implement `PlayerView+iOS.swift`: adapt layout for portrait/landscape; UIImage dominant-color extraction
- [ ] Implement `PlaylistView+iOS.swift`: inline playlist (not a separate window); swipe-to-remove replaces menu action
- [ ] Implement `WelcomeView+iOS.swift`: library folder picker using `.fileImporter`
- [ ] Add touch drag-and-drop for tracks (library → playlist, playlist reorder) using `onDrag`/`onDrop` with iOS item providers
- [ ] Add icon affordances for actions that are menu-only on macOS (Remove from Playlist, Edit Metadata, etc.)
- [ ] Handle iPad split-screen and Stage Manager layouts

### Phase 5 — Polish and Parity

- [ ] Implement `TrackMetadataEditorView` adaptations for iOS (sheet presentation instead of panel)
- [ ] Implement `RatingView` touch affordances
- [ ] Implement `WaveformSeekBar` touch scrubbing
- [ ] Add Now Playing / Control Center integration (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`)
- [ ] Test library sync via iCloud Drive (Mac writes, iPad reads)
- [ ] Run on physical iPad hardware; fix layout issues
- [ ] Resolve any remaining `#if os(macOS)` guards in shared code
