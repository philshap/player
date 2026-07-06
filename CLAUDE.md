# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

This is an Xcode project. All commands should be run from the repository root (which contains `player.xcodeproj`).

```bash
# Build (macOS)
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

### Playlist Change Observation

`PlaylistManager` posts `.playlistDidChange` notifications (with `playlistID` in userInfo) whenever a playlist is mutated. `MainPlaybackController` observes these to keep its in-memory `[Track]` array in sync with the SwiftData model and to invalidate/restart prefetch when the playlist is reordered while playing.

### Multi-Window Layout

The app uses three window types (defined in `playerApp.swift`):
- `Window("Library", id: "library")` — `LibraryView`
- `Window("Player", id: "player")` — `PlayerView`
- `WindowGroup("Playlist", id: "playlist", for: String.self)` — `PlaylistWindowView`, one per playlist

Global keyboard shortcuts are registered via `CommandMenu("Playback")` in the scene's `.commands` modifier.

<!-- rtk-instructions v2 -->
# RTK (Rust Token Killer) - Token-Optimized Commands

## Golden Rule

**Always prefix commands with `rtk`**. If RTK has a dedicated filter, it uses it. If not, it passes through unchanged. This means RTK is always safe to use.

**Important**: Even in command chains with `&&`, use `rtk`:
```bash
# ❌ Wrong
git add . && git commit -m "msg" && git push

# ✅ Correct
rtk git add . && rtk git commit -m "msg" && rtk git push
```

## RTK Commands by Workflow

### Build & Compile (80-90% savings)
```bash
rtk cargo build         # Cargo build output
rtk cargo check         # Cargo check output
rtk cargo clippy        # Clippy warnings grouped by file (80%)
rtk tsc                 # TypeScript errors grouped by file/code (83%)
rtk lint                # ESLint/Biome violations grouped (84%)
rtk prettier --check    # Files needing format only (70%)
rtk next build          # Next.js build with route metrics (87%)
```

### Test (60-99% savings)
```bash
rtk cargo test          # Cargo test failures only (90%)
rtk go test             # Go test failures only (90%)
rtk jest                # Jest failures only (99.5%)
rtk vitest              # Vitest failures only (99.5%)
rtk playwright test     # Playwright failures only (94%)
rtk pytest              # Python test failures only (90%)
rtk rake test           # Ruby test failures only (90%)
rtk rspec               # RSpec test failures only (60%)
rtk test <cmd>          # Generic test wrapper - failures only
```

### Git (59-80% savings)
```bash
rtk git status          # Compact status
rtk git log             # Compact log (works with all git flags)
rtk git diff            # Compact diff (80%)
rtk git show            # Compact show (80%)
rtk git add             # Ultra-compact confirmations (59%)
rtk git commit          # Ultra-compact confirmations (59%)
rtk git push            # Ultra-compact confirmations
rtk git pull            # Ultra-compact confirmations
rtk git branch          # Compact branch list
rtk git fetch           # Compact fetch
rtk git stash           # Compact stash
rtk git worktree        # Compact worktree
```

Note: Git passthrough works for ALL subcommands, even those not explicitly listed.

### GitHub (26-87% savings)
```bash
rtk gh pr view <num>    # Compact PR view (87%)
rtk gh pr checks        # Compact PR checks (79%)
rtk gh run list         # Compact workflow runs (82%)
rtk gh issue list       # Compact issue list (80%)
rtk gh api              # Compact API responses (26%)
```

### JavaScript/TypeScript Tooling (70-90% savings)
```bash
rtk pnpm list           # Compact dependency tree (70%)
rtk pnpm outdated       # Compact outdated packages (80%)
rtk pnpm install        # Compact install output (90%)
rtk npm run <script>    # Compact npm script output
rtk npx <cmd>           # Compact npx command output
rtk prisma              # Prisma without ASCII art (88%)
```

### Files & Search (60-75% savings)
```bash
rtk ls <path>           # Tree format, compact (65%)
rtk read <file>         # Code reading with filtering (60%)
rtk grep <pattern>      # Search grouped by file (75%)
rtk find <pattern>      # Find grouped by directory (70%)
```

### Analysis & Debug (70-90% savings)
```bash
rtk err <cmd>           # Filter errors only from any command
rtk log <file>          # Deduplicated logs with counts
rtk json <file>         # JSON structure without values
rtk deps                # Dependency overview
rtk env                 # Environment variables compact
rtk summary <cmd>       # Smart summary of command output
rtk diff                # Ultra-compact diffs
```

### Infrastructure (85% savings)
```bash
rtk docker ps           # Compact container list
rtk docker images       # Compact image list
rtk docker logs <c>     # Deduplicated logs
rtk kubectl get         # Compact resource list
rtk kubectl logs        # Deduplicated pod logs
```

### Network (65-70% savings)
```bash
rtk curl <url>          # Compact HTTP responses (70%)
rtk wget <url>          # Compact download output (65%)
```

### Meta Commands
```bash
rtk gain                # View token savings statistics
rtk gain --history      # View command history with savings
rtk discover            # Analyze Claude Code sessions for missed RTK usage
rtk proxy <cmd>         # Run command without filtering (for debugging)
rtk init                # Add RTK instructions to CLAUDE.md
rtk init --global       # Add RTK to ~/.claude/CLAUDE.md
```

## Token Savings Overview

| Category | Commands | Typical Savings |
|----------|----------|-----------------|
| Tests | vitest, playwright, cargo test | 90-99% |
| Build | next, tsc, lint, prettier | 70-87% |
| Git | status, log, diff, add, commit | 59-80% |
| GitHub | gh pr, gh run, gh issue | 26-87% |
| Package Managers | pnpm, npm, npx | 70-90% |
| Files | ls, read, grep, find | 60-75% |
| Infrastructure | docker, kubectl | 85% |
| Network | curl, wget | 65-70% |

Overall average: **60-90% token reduction** on common development operations.
<!-- /rtk-instructions -->
