# Player - DJ Playlist Player

## Overview

A DJ-oriented audio player for macOS (iOS later) focused on playlist curation and live performance playback. The app manages a personal music library, supports creating and managing multiple playlists, and provides a split-mono headphone preview system for cueing tracks during live playback.

## Platform

- macOS first (multi-window)
- iOS planned for later (UI TBD)

## Core Concepts

### Library
- The app maintains its own music library, independent of the system music library
- Users import local audio files into the library
- Library stores and displays track metadata (title, artist, album, genre, BPM, duration, etc.)
- Library is searchable and sortable by metadata fields

### Playlists
- Users can create any number of playlists
- Playlists are ordered lists of tracks from the library
- Tracks can appear in multiple playlists
- Playlists can be reordered via drag-and-drop

### Playback
- The main output plays the current playlist sequentially
- Playback controls: play, pause, stop, next track, previous track, seek
- Tracks transition sequentially (crossfade between tracks is a nice-to-have, not required)

### Track Preview (Cue/Headphone Monitor)
- While a playlist is playing on the main output, the user can preview/cue any track from the library or a playlist
- Uses a mono split-cable approach:
  - All audio is mixed down to mono
  - Left channel: main playlist output
  - Right channel: preview/cue output
- This allows the DJ to use a standard stereo headphone output with a split cable, hearing the main mix in one ear and the preview in the other
- Preview controls: play, pause, stop, seek

## App Modes

### Curation Mode (default)
- Full access to library management, playlist editing, metadata browsing
- Standard mouse/trackpad interaction
- Multi-window layout

### Performance Mode
- Optimized for live playback
- Keyboard shortcuts for all common playback actions:
  - Play/pause main output
  - Next/previous track
  - Play/pause preview
  - Load selected track into preview
  - Seek forward/back (main and preview)
  - Switch between playlists
- Minimal UI distractions; focus on what's playing and what's next

## macOS UI (Multi-Window)

### Library Window
- Displays all tracks in the library with metadata columns
- Search bar for filtering by metadata
- Import button / drag-and-drop to add files
- Right-click context menu to add tracks to playlists
- Sortable columns (title, artist, album, genre, BPM, duration)

### Player Window
- Shows currently playing track info (title, artist, album art if available)
- Playback controls (play, pause, stop, next, previous, seek bar)
- Preview/cue section with its own controls and track info
- Visual indication of which channel is which (main vs. preview)
- Volume controls for main and preview

### Playlist Windows
- Each playlist opens in its own window
- Ordered track list with metadata columns
- Drag-and-drop reordering
- Add/remove tracks
- Double-click or keyboard shortcut to load track into main player or preview
- Highlight for currently playing track

## Audio Architecture

- Built on AVFoundation / AVAudioEngine
- Two AVAudioPlayerNodes: one for main output, one for preview
- Mono mixdown of both signals
- Channel routing: main -> left, preview -> right
- Output through system default audio device

## Data Model

### Track
- File path / URL (local file reference)
- Title
- Artist
- Album
- Genre
- Duration
- BPM (nice-to-have: auto-detection)
- Date added
- In/out cue points (nice-to-have)

### Playlist
- Name
- Ordered list of track references
- Date created / modified

### Library
- Collection of all imported tracks
- Persisted locally (Core Data or SwiftData)

## File Sources

### v1
- Local audio files (MP3, AAC, WAV, AIFF, etc.)
- Import via file picker or drag-and-drop
- Uses AVFoundation for playback

### Future
- Apple Music library integration
- Streaming sources (Apple Music, Spotify)

## Nice-to-Have Features (not required for v1)

- Crossfade between playlist tracks
- Waveform display for tracks
- BPM auto-detection
- In/out cue point selection and saving
- Album art display

## Out of Scope

- Audio EQ (handled externally)
- Looping
- Beatmatching
- Effects processing
- Recording/mixing output
