# Player - Remaining Tasks

Organized by difficulty and importance. See TASKS-DONE.md for completed work.


## High Priority

### Misc bugs / features

### Code cleanups

- find out if we really need playlist entry sortOrder, if playlist entries are always in sort order. Right now the code
  sorts the entries in a few different places, which wouldn't be needed if the list was always in sort order.

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

