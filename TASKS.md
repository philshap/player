# Player - Remaining Tasks

Organized by difficulty and importance. See TASKS-DONE.md for completed work.


## High Priority

### Misc
- allow multiple seleection in playlist window
- in player window, use performance UI for non-performance main playback
- track art lookup in itunes should use album as well as artist and title, if track has album set
- when dragging a selection of tracks onto the "New Playlist" button, there's no postiive drop feedback on the New Playlist button

---

## Medium Priority / Medium Difficulty

### Composite filtering in Library
- use a filter rule to limit library view, which can combine text search, tags and other attribute filters
- Possibly fold tag search into this filter view, use an expandable header area
- for numeric files, support uspper / lower bounds
- for dates, support before / after
- for text, support contains / does not contain
- no need to support multiple filters on the same attribute, but could allow it if makes filtering more general
- example filter tasks are "BPM greater than X and less than Y", "Play count less then X", "Last Played date before X"
- Once done, may want a way to save / load named filters

### Keep updating playback position display while mouse is pressed
- Position display stops running on mouse down and "jumps" on mouse up, such as on a menu item
- Nice to have; if this requires major changes it may not be worth doing

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

