# Portable Library

## Goal

Bundle the app, SwiftData library, and all referenced audio files into a single folder on a removable drive, so the library can be built on one Mac and used for performance on another.

## Design: Portable Library Folder

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

## Key Design Decisions

### 1. Relative paths instead of absolute URLs

Tracks store a path relative to the library folder root (e.g. `Music/Artist - Title.mp3`) in `Track.relativePath`. An absolute URL would break when the drive mounts at a different path or on another machine.

`Track.accessibleURL(libraryFolderURL:)` resolves the relative path against the currently open library folder at runtime.

### 2. Single folder-level security-scoped bookmark

One bookmark for the library folder itself is stored in `UserDefaults` (`"libraryFolderBookmark"`). All file access is relative to this folder — no fragile per-track bookmarks.

On launch, the bookmark is resolved and `startAccessingSecurityScopedResource()` is called once for the folder; every track file inside is then readable.

### 3. SwiftData store inside the library folder

The store URL is passed explicitly to `ModelConfiguration` (`libraryFolderURL/library.sqlite`) instead of using the default Application Support container, so the database travels with the audio files.

### 4. Copy-on-import

When the user adds tracks, the app **copies** the audio file into `Music/` before creating the `Track` record. The source file is untouched; the library always owns its own copy.

- Duplicate filenames get a counter suffix (`Track (2).mp3`)
- When the user deletes a track, the library's copy is moved to the trash
- The library window footer shows the free disk space on the library volume

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

## App Distribution

Since the app is signed with a personal Apple Developer certificate, it runs on any Mac you own:
- First launch on a new machine: Gatekeeper shows "cannot verify developer"
- Fix: System Settings → Privacy & Security → "Open Anyway" (once per machine)
- Or: notarize the app via Xcode Organizer for a cleaner experience

## Out of Scope

- Conflict resolution if the same library folder is opened on two machines simultaneously
- Syncing changes back (two-way merge) — the intended workflow is one active machine at a time
- Network volumes (works in principle, but no special handling needed)
