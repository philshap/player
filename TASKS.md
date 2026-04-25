# Player - Remaining Tasks

Organized by difficulty and importance. See TASKS-DONE.md for completed work.


## High Priority

### Misc bugs / features
- show bpm for currently playing performance track
- in performance playback view, show info for next track that will be played: artwork, track, artist, bpm, track length
- show larger artwork in performance playback?
- maybe use album cover to "tint" window background color simliar to safari web pages?
- when detecting bpm, quantize to multiple of 5, e.g. 104 -> 105, 99 -> 100, 101 -> 100.
- the app asks on launch to access apple music, is there a way to defer the request until apple music access is needed, before trying to access metadata?

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
- Monitor audio engine for underruns
- Possibly use higher-priority thread for audio scheduling

---

## Low Priority / Low Difficulty

- remove old support for non-directory libraries. Or, add it back as an option to select so user can choose which model they want


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

