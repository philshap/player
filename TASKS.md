# Player - Remaining Tasks

Organized by difficulty and importance. See TASKS-DONE.md for completed work.

---

## High Priority / Medium Difficulty

### Waveform Display
- Render audio waveform for current track in performance controls
- Show playback position on waveform
- Could replace or augment the seek slider
- Requires reading audio samples, downsampling, and custom Canvas/Path rendering

### External Soundcard Support
- Route main and preview to specific audio output devices
- Support USB soundcards (e.g. Traktor Audio 2)
- Would need AVAudioEngine output node configuration per device
- Critical for real DJ use (headphone cueing on separate output)

---

## Medium Priority / Low Difficulty

### BPM Detection
- Auto-detect BPM for tracks that don't have it in file metadata
- Could use onset detection / autocorrelation on audio samples
- Run on import or on-demand from context menu
- Display already exists in library and playlist views

### Keyboard Shortcut Expansion
- Seek forward/back for preview
- Jump to cue in/out via keyboard
- Load selected library track into preview
- These shortcuts exist in menus but may need refinement

---

## Medium Priority / Medium Difficulty

### Playlist Organization
- As playlist count grows, sidebar becomes hard to navigate
- Options: archive/active sections, document-based playlists, folders
- Deferred for now — revisit when list gets long

---

## Low Priority / Low Difficulty

### UI Polish (Remaining)
- Drag & drop feedback shows track name (or "N tracks" for multi-select)
- Drag into playlist from library at specific position with insertion feedback

---

## Low Priority / High Difficulty

### Portable Performance Mode
- Bundle app + library + audio files onto a removable drive
- Run on another Mac without installation
- Needs file path remapping, self-contained data store
- Complex due to code signing, sandboxing, and file references

### Audio Reliability
- Investigate and prevent audio glitches during performance
- Pre-buffer next track before auto-advance
- Monitor audio engine for underruns
- Possibly use higher-priority thread for audio scheduling
