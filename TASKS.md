# Player - Remaining Tasks

Organized by difficulty and importance. See TASKS-DONE.md for completed work.

---

## Medium Priority / Medium Difficulty

### Audio Level Display
- Using bar graph or analog-style VU meter, show audio playback level for both playback channels

### Waveform Display
- Render audio waveform for current track in performance controls
- Show playback position on waveform
- Could replace or augment the seek slider
- Requires reading audio samples, downsampling, and custom Canvas/Path rendering

### External Soundcard Support
- Route main and preview to specific audio output devices
- Support USB soundcards (e.g. Traktor Audio 2)
- Would need AVAudioEngine output node configuration per device

---

## Medium Priority / High Difficulty

### Audio Reliability
- Investigate and prevent audio glitches during performance
- Pre-buffer next track before auto-advance
- Monitor audio engine for underruns
- Possibly use higher-priority thread for audio scheduling

---

## Low Priority / Low Difficulty

### Keyboard Shortcut Expansion
- Seek forward/back for preview
- Jump to cue in/out via keyboard
- Load selected library track into preview
- These shortcuts exist in menus but may need refinement

### UI Polish
- Nicer playback controller with icons/graphics, maybe larger buttons

---

## Low Priority / Medium Difficulty

### Playlist Organization
- As playlist count grows, sidebar becomes hard to navigate
- Options: archive/active sections, document-based playlists, folders
- Deferred for now — revisit when list gets long

---

## Low Priority / High Difficulty

### Portable Library
- Bundle app + library + audio files onto a removable drive or self-contained folder
- Replace per-track bookmarks + absolute URLs with a single folder-level bookmark and relative paths
- Store SwiftData at a configurable URL within the library folder
- Copy-on-import: audio files copied into Music/ subfolder
- Launch onboarding: "New Library" / "Open Library" panel
- Migration path for existing libraries
- See PORTABLE-LIBRARY.md for detailed design
