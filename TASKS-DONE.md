# Player - Completed Tasks

## Phase 1: Data Layer (Complete)

### 1.1 SwiftData Models
- Track model with all metadata fields (title, artist, album, duration, BPM, rating, date added, play count, last played, file URL, cue points, artwork)
- Playlist model (name, ordered track references via PlaylistEntry, date created/modified)
- SwiftData ModelContainer in app entry point

### 1.2 Library Import Service
- File picker for importing local audio files (MP3, AAC, WAV, AIFF, FLAC, M4A)
- Drag-and-drop import from Finder
- Auto-extract metadata (title, artist, album, duration, BPM, album art) via AVFoundation
- Security-scoped bookmarks for persistent file access
- Duplicate detection by file URL

### 1.3 Playlist CRUD
- Create, rename, delete playlists
- Add/remove tracks from playlists
- Reorder tracks within a playlist (drag-and-drop)

## Phase 2: Audio Engine (Complete)

### 2.1 Audio Engine Core
- Two AVAudioPlayerNodes: main and preview
- Mono mixdown for both channels
- Channel routing: main -> left, preview -> right

### 2.2 Main Playback Controller
- Play/pause/stop, next/previous, seek
- Sequential playlist playback with auto-advance
- Play count and last played tracking on track completion
- Generation counter pattern for safe async completion callbacks
- Inter-track gap timer with configurable pause (0/1/2/3/5 seconds)

### 2.3 Preview Playback Controller
- Independent play/pause/stop and seek
- Volume control
- Proper resume (not restart) on play after pause

## Phase 3: macOS UI (Complete)

### 3.1 App Shell & Navigation
- Multi-window support (library + per-playlist windows)
- Menu bar with keyboard shortcuts
- App mode toggle (Curation / Performance)

### 3.2 Player Window
- Playback controls integrated into playlist window (performance mode)
- Preview/cue section in separate PlayerView

### 3.3 Library Window
- Sortable table with value-type TrackRow for performance (500+ tracks)
- Search filtering across title, artist, album
- File import button + drag-and-drop from Finder
- Context menu: add to playlist, load in preview, delete
- Whole-row drag support via TableRow.draggable
- Album art thumbnail column

### 3.4 Playlist Window
- Track list with BPM, rating (editable), play count, duration, cue point indicators, album art
- Drag-and-drop reordering within playlist
- Drag-and-drop from library into playlist (including during performance mode)
- Context menu: play from here, load in preview, set/clear cue points, remove
- Progress bar background on currently playing track (isolated observation)
- Playlist statistics footer (track count, duration, BPM range, avg rating, unplayed count)
- Window closes automatically on playlist delete

## Phase 4: Performance Mode & Keyboard Controls (Complete)

### 4.1 Keyboard Shortcuts
- Play/pause main and preview
- Next/previous track
- Seek forward/back

### 4.2 Performance Mode UI
- Toggle between Curation and Performance modes
- Performance mode: lock editing (no reorder, rename, delete)
- Performance controls on playlist window (transport, seek, gap picker)
- Track info with album art in performance controls

### 4.3-4.5 Bug Fixes
- Rating on track metadata
- Metadata and BPM extraction from file tags
- Drag-and-drop fixes (library to playlist, reorder in playlist, whole-row drag)
- Track skipping race condition (generation counter)
- Preview restart on play (now resumes properly)
- Library table performance (value-type rows, pre-formatted strings, .id(generation))
- Drag target flickering during playback (isolated observation subviews)
- Playlist window close on delete

## Phase 5: Polish (Partial)

### 5.1 Inter-track Pause (Complete)
- Configurable gap duration (0/1/2/3/5 seconds)
- Countdown display with skip button
- Cancelled by manual next/previous/stop

### 5.3 Cue Points (Complete)
- Set cue in/out at current playback position via context menu
- Jump to cue in
- Auto-advance when cue-out reached
- Visual indicators in playlist rows
- Clear cue points action

### 5.4 Playlist Statistics (Complete)
- Footer bar: track count, total duration, BPM range, average rating, unplayed count

### 5.6 UI Polish (Partial - Complete Items)
- Album art in library table, playlist rows, and performance controls
- Sort ignoring leading "The" in title and album
- Drag onto New Playlist creates playlist with dropped tracks
- Drag target highlight feedback on playlist sidebar items

## Phase 6: Refactoring (Complete)

### 6.1 Shared Utilities
- Extracted `clamped(to:)` to a shared `extension Comparable` in `Utilities.swift` (was duplicated as private extensions in `AudioEngineManager` and `MainPlaybackController`)
- Extracted time formatting to `TimeInterval.mmss()` in `Utilities.swift` (was duplicated as private `formatTime`/`formatDuration`/`formatCueTime` methods in `PlayerView`, `PlaylistWindowView`, `TrackMetadataEditorView`, and `TrackRow`)

### 6.2 Shared TrackInfoView Component
- Added `TrackInfoView` (artwork + title/artist label) to replace repeated HStack/VStack layout in `PlayerView` (main section, preview section) and `PlaylistWindowView` (performance controls)
