# Player - Remaining Tasks

Organized by difficulty and importance. See TASKS-DONE.md for completed work.


## High Priority

### Misc bugs / features

- open playlist windows aaren't re-opened when app starts up

- diagnose / fix warning "It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out.  If you are implementing the view's -layout method, you can call -[super layout] instead.  Break on void _NSDetectedLayoutRecursion(void) to debug.  This will be logged only once.  This may break in the future."

- don't start playback when audio output changes if playback is paused

### Code cleanups

---

## Medium Priority / Medium Difficulty

### Audio Level Display
- Using bar graph or analog-style VU meter, show audio playback level for both playback channels

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

- remove support for non-directory libraries. Or, add it back as an option to select so user can choose which model they want


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

