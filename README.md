# Player

A Swing DJ-oriented audio player for macOS. Manage a music library, build playlists, and cue upcoming tracks
through a split-mono headphone monitor.

## Features

- **Portable library** — music files are copied into a self-contained library folder that can live on a USB drive
- **Playlists** — create and manage playlists with drag-and-drop reordering
- **Split-mono preview** — cue the next track in your headphones while the main output keeps playing; left channel = main output, right channel = preview/cue
- **BPM detection** — automatic BPM analysis on import
- **Track metadata editing** — edit title, artist, album, BPM, rating, cue points and tags
- **Inter-track gap** — configurable gap (0–5 s) between tracks with countdown
- **System volume control** — micro-adjust the Mac's output volume from the Player window
- **Apple Music artwork** — falls back to the system iTunes/Music library for artwork when none is embedded in the file

## Requirements

- macOS 26 or later
- Xcode 26 or later (to build from source)

## Why another DJ program?

There are many DJ and music management programs, but I wanted one for swing dance DJ'ing. Swing dance DJ'ing doesn't
require beat matching or crossfade, doesn't use loops or effects on tracks. I also wanted the
ability to store the music library and program on a removable drive so it can be used with any Mac system without
needing to install anything.

## Audio support

This player supports split-mono output to support track preview while another track is being played for performance.
This works by mixing all tracks down to mono and using one channel for preview and the other for performance. To
use this, you'll need an audio split cable, which splits the L/R signal into two separate mono outputs, and two
mono-to-stereo adaptors, which duplicate the mono signal on both channels. Your headphones plug into one output, and
the PA/amp system plugs into the other one.

```
      Mac stereo output
             │
      stereo split cable
      ┌──────┴──────┐
   L (main)      R (cue)
      │             │
 mono→stereo   mono→stereo
   adaptor       adaptor
      │             │
   PA / amp     headphones
```

Either output can also be switched to normal stereo from the Player window (e.g. headphone-only preview at home,
or full-stereo main output when no cue monitoring is needed).

## Architecture

See [CLAUDE.md](CLAUDE.md) for a detailed architecture overview, including the playback class hierarchy, audio engine channel-isolation approach, generation-counter pattern, and portable library design.

## License

Copyright © 2025 Phil Shapiro. All rights reserved.
