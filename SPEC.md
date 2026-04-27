# Player - DJ Playlist Player

## Overview

A DJ-oriented audio player for macOS (iOS later) focused on playlist curation and live performance playback. The app manages a personal music library, supports creating and managing multiple playlists, and provides a split-mono headphone preview system for cueing tracks during live playback.

## Platform

- macOS first (multi-window)
- iOS planned for later (UI TBD)

## Core Concepts

### Library
- The app maintains its own music library, independent of the system music library
- Users import local audio files into the library; files are copied into the library folder on import
- Library stores and displays track metadata (title, artist, album, genre, BPM, duration, etc.)
- Library is searchable and sortable by metadata fields
- The library is a self-contained folder (SQLite store + Music/ subfolder) that can be placed on a USB drive and used on any Mac — see [PORTABLE-LIBRARY.md](PORTABLE-LIBRARY.md) for the full design

### Playlists
- Users can create any number of playlists
- Playlists are ordered lists of tracks from the library
- Tracks can appear in multiple playlists
- Playlists can be reordered via drag-and-drop

### Playback
- The main output plays the current playlist sequentially
- Playback controls: play, pause, stop, next track, previous track, seek, restart track
- Tracks transition sequentially with configurable inter-track gap (0/1/2/3/5 seconds) and a countdown/skip UI
- Next track pre-buffered in memory during playback so that auto-advance is instant (no disk read at the track boundary)

### Track Preview (Cue/Headphone Monitor)
- While a playlist is playing on the main output, the user can preview/cue any track from the library or a playlist
- Uses a mono split-cable approach:
  - All audio is mixed down to mono
  - Left channel: main playlist output
  - Right channel: preview/cue output
- Each channel has an independently configurable routing mode: left-only (mono-split cable) or both channels (stereo monitoring)
- This allows the DJ to use a standard stereo headphone output with a split cable, hearing the main mix in one ear and the preview in the other
- Preview controls: play, pause, stop, seek, volume
- Note: An alternative deck-based A/B model (where you preview in the free deck and swap) is possible but not the initial approach. Worth revisiting if the mono-split model proves limiting.

## App Modes

The primary concern is preventing accidental modifications during live playback — e.g., accidentally pausing music or editing the active playlist. Keyboard controls are important in both modes since mouse use can be awkward in a DJ setting.

### Curation Mode (default)
- Full access to library management, playlist editing, metadata browsing
- Standard mouse/trackpad + keyboard interaction
- Multi-window layout
- Editing playlists, importing tracks, managing metadata

### Performance Mode
- Playlist and library content is read-only (no accidental edits to the playing playlist)
- Keyboard shortcuts for all common playback actions:
  - Play/pause main output
  - Next/previous track
  - Play/pause preview
  - Load selected track into preview
  - Seek forward/back (main and preview)
  - Switch between playlists
- Minimal UI distractions; focus on what's playing and what's next
- Keyboard-first interaction model
- Performance controls shown only in the active playlist's window

## macOS UI (Multi-Window)

### Library Window
- Displays all tracks in the library with metadata columns (art, title, artist, album, BPM, rating, duration, play count, last played, cue points)
- Search bar for filtering by metadata
- Import button / drag-and-drop to add files
- Context menu: add to playlist, load in preview, set/clear cue points, detect BPM, edit metadata, delete
- Sortable columns; sort ignores leading "The" in title and album
- Sidebar with playlist list; drag tracks from table to playlist or to a "New Playlist" drop target
- Whole-row drag support for multi-track selection

### Player Window
- Shows currently playing track info (title, artist, album art)
- Playback controls (play, pause, stop, next, previous, restart, seek bar)
- Preview/cue section with its own controls and track info
- Channel routing toggle per output (left-only vs. both channels)
- Volume control for preview

### Playlist Windows
- Each playlist opens in its own window
- Ordered track list with metadata columns (art, title, artist, BPM, rating, play count, duration, cue point indicators)
- Drag-and-drop reordering within playlist
- Drag-and-drop from library into playlist (including during performance mode)
- Context menu: play from here, load in preview, jump to cue in, clear cue points, remove
- Progress bar background on currently playing track
- Playlist statistics footer: track count, total duration, BPM range/avg, average rating, unplayed count
- Window closes automatically on playlist delete
- Performance controls (seek bar, transport, gap picker) shown in the active playlist's window during performance mode

## Audio Architecture

- Built on AVFoundation / AVAudioEngine
- Two AVAudioPlayerNodes: one for main output, one for preview
- All audio pre-decoded to in-memory AVAudioPCMBuffer before scheduling; eliminates disk I/O on the render thread
- Next track pre-buffered in the background during playback; auto-advance schedules the buffer directly without a disk read
- Mono mixdown of both signals; channel routing enforced by buffer content (not pan)
- Channel routing: main → left (or both), preview → right (or both)
- Output through system default audio device
- Generation counter pattern prevents stale completion callbacks

## Data Model

### Track
- Relative path within the library folder (resolved at runtime against the library folder URL)
- Title, artist, album
- Genre
- Duration
- BPM (auto-detected on import via energy-envelope autocorrelation if not in file tags; editable)
- Date added
- Play count and last played date
- Rating (0–5 stars)
- Cue point in / cue point out (set from playback position; auto-advance on cue-out)
- Album artwork (stored as JPEG thumbnail, up to 200px)

### Playlist
- Name
- Ordered list of track references (`Playlist.tracks`)
- Date created / modified

### Playlist Statistics
- Track count, total duration
- BPM range and average
- Average rating
- Unplayed track count (play count == 0)

### Library
- Collection of all imported tracks
- Persisted as a portable folder: SwiftData store (`library.sqlite`) + `Music/` subfolder, all at a user-chosen location
- Single folder-level security-scoped bookmark stored in UserDefaults; tracks use relative paths within the folder
- Future consideration: shared document state between platforms via iCloud

## File Sources

### v1
- Local audio files (MP3, AAC, WAV, AIFF, FLAC, M4A)
- Import via file picker or drag-and-drop
- Uses AVFoundation for playback

### Future
- Apple Music library integration
- Streaming sources (Apple Music, Spotify)

## Nice-to-Have Features (not required for v1)

- Crossfade between playlist tracks
- Waveform display for tracks
- Audio level / VU meter display
- External soundcard routing (e.g. USB devices like Traktor Audio 2)

## Out of Scope

- Audio EQ (handled externally)
- Looping
- Beatmatching
- Effects processing
- Recording/mixing output
