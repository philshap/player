# Player

A DJ-oriented audio player for macOS. Manage a personal music library, build playlists, and cue upcoming tracks through a split-mono headphone monitor — all without leaving the app.

## Features

- **Personal library** — import local audio files; files are copied into a self-contained library folder (SQLite + Music/ subfolder) that can live on a USB drive
- **Playlists** — create and manage multiple playlists with drag-and-drop reordering; tracks can appear in multiple playlists
- **Split-mono preview** — cue the next track in your headphones while the main output keeps playing; left channel = main output, right channel = preview/cue
- **Waveform seek bar** — visual playback position with click-to-seek
- **BPM detection** — automatic BPM analysis on import
- **Track metadata editing** — edit title, artist, album, BPM, rating, and cue points
- **Inter-track gap** — configurable gap (0–5 s) between tracks with countdown UI
- **Apple Music artwork** — falls back to the system iTunes/Music library for artwork when none is embedded in the file

## Requirements

- macOS 15 or later
- Xcode 16 or later (to build from source)

## Building

```bash
# Open in Xcode
open player.xcodeproj

# Or build from the command line (from the player/ subdirectory)
xcodebuild -project player.xcodeproj -scheme player -destination 'platform=macOS' build

# Run tests
xcodebuild test -project player.xcodeproj -scheme player -destination 'platform=macOS'
```

## Architecture

See [CLAUDE.md](CLAUDE.md) for a detailed architecture overview, including the playback class hierarchy, audio engine channel-isolation approach, generation-counter pattern, and portable library design.

## License

Copyright © 2025 Phil Shapiro. All rights reserved.
