# Portable Library Feature

## Goal

Bundle the app, SwiftData library, and all referenced audio files into a single folder on a removable drive, so the library can be built on one Mac and used for performance on another.

## Chosen Approach: Portable Library Folder

One self-contained folder holds everything:

```
/Volumes/USB Drive/DJLibrary/
  player.app              ← copy of the built app (optional, for convenience)
  library.sqlite          ← SwiftData store
  library.sqlite-wal      ← (WAL journal, present while app is running)
  library.sqlite-shm      ← (shared memory file, present while app is running)
  Music/
    Artist - Title.mp3
    Artist - Title.flac
    ...
```

The app is document-oriented at the folder level: it opens (or creates) a library folder and reads everything from it. The same folder on a USB drive works on any Mac.

---

## Key Design Decisions

### 1. Relative paths instead of absolute URLs

`Track.fileURL` currently stores an absolute URL (`/Users/phil/Music/...`). This breaks on another machine.

**Change:** Store a path relative to the library folder root, e.g. `Music/Artist - Title.mp3`.

`Track.accessibleURL()` resolves this against the current library folder URL:
```swift
libraryFolderURL.appending(path: track.relativePath)
```

### 2. Single folder-level security-scoped bookmark

Currently each `Track` holds its own `bookmarkData` (a per-file security-scoped bookmark). These are fragile across machines and paths.

**Change:** One bookmark for the library folder itself, stored in `UserDefaults`. All file access is relative to this folder — no per-track bookmarks needed.

```swift
// On open:
let folderURL = resolveLibraryFolderBookmark()
folderURL.startAccessingSecurityScopedResource()
// All track file I/O works without further bookmarks
```

### 3. SwiftData store at a configurable URL

Currently the store lives in `~/Library/Application Support/` (default container). 

**Change:** Pass an explicit URL to `ModelConfiguration`:
```swift
ModelConfiguration(url: libraryFolderURL.appending(path: "library.sqlite"))
```

This means the database travels with the audio files.

### 4. Copy-on-import

When the user adds tracks, the app **copies** the audio file into `Music/` before creating the `Track` record. The source file is untouched; the library always owns its own copy.

- Duplicate filenames: append a counter suffix (`Track (2).mp3`)
- Large files: show progress (can be async with a Task)

---

## Required Code Changes

### `Models.swift`
- Add `var relativePath: String` to `Track` (replaces meaningful use of `fileURL`)
- Keep `fileURL` or repurpose it for display; remove `bookmarkData`

### `playerApp.swift` / `AppState.swift`
- On launch: if no library folder bookmark exists, show "New Library" / "Open Library" panel
- Store folder bookmark in `UserDefaults`
- Resolve bookmark and call `startAccessingSecurityScopedResource()` for the folder
- Pass resolved folder URL into the SwiftData container and all managers

### `LibraryManager.swift`
- `importTracks(urls:)`: copy each file to `libraryFolder/Music/`, store relative path
- Remove bookmark-creation logic (no longer needed)
- Add `relocateLibrary(to:)` for moving an existing library folder

### `Track.accessibleURL()`
- Resolve `relativePath` against `AppState.libraryFolderURL`
- Remove `resolveBookmark()` — no longer needed

### `TrackMetadataEditorView.swift`
- No changes needed (edits metadata fields only)

### App entitlements
- Keep `com.apple.security.files.user-selected.read-write` (already present)
- The single folder grant covers all file access within it

---

## Launch / Onboarding Flow

```
App launches
    │
    ├─ UserDefaults has library folder bookmark?
    │       │
    │      YES → resolve bookmark → start accessing → load SwiftData → show main UI
    │       │
    │       NO → show welcome sheet
    │               ├─ "New Library…"  → NSSavePanel (choose folder location)
    │               │                   create folder + Music/ subfolder
    │               │                   store bookmark → proceed as above
    │               └─ "Open Library…" → NSOpenPanel (pick existing library folder)
    │                                   store bookmark → proceed as above
```

---

## Migration for Existing Libraries

Users with an existing library (absolute paths, per-file bookmarks) need a one-time migration:

1. Show "Migrate Library" sheet on first launch after update
2. Ask user to choose a destination folder (or create one)
3. Copy all tracked files into `Music/` subfolder
4. Update each `Track.relativePath` to the new relative path
5. Move (or recreate) the SwiftData store at the new location
6. Clear old per-file bookmark data

---

## App Distribution

Since the app is signed with your Apple Developer certificate, it runs on any Mac you own:
- First launch on the new machine: Gatekeeper shows "cannot verify developer" 
- Fix: System Settings → Privacy & Security → "Open Anyway" (once per machine)
- Or: notarize the app via Xcode Organizer for a cleaner experience

---

## Out of Scope (for now)

- Conflict resolution if the same library folder is opened on two machines simultaneously
- Syncing changes back (two-way merge) — the intended workflow is one active machine at a time
- Network volumes (works in principle, but no special handling needed)
