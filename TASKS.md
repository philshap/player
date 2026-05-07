# Player - Remaining Tasks

Organized by difficulty and importance. See TASKS-DONE.md for completed work.


## High Priority

### Misc
- add copyright, readme, etc to repo
- add version, add CI rule to bump version on merge to main branch before CI tests run
  - maybe create release after successful CI build, and auto-produce change notes based on commit messages?

---

## Medium Priority

### Misc

- track art lookup in Apple Music should use album as well as artist and title, if track has album set
- when dragging a selection of tracks onto the "New Playlist" button, there's no drop feedback on the New Playlist button
- allow multiple selection in playlist window, for bulk drag and remove operations
- main and preview player UI album art display overlaps left-hand time display

### Unify playlist playback display with player
  - use player's main controller view directly in playlist, or provide same UI
  - need to add Gap dropdown and gap timing display to player view


### Composite filtering in Library
- use a filter rule to limit library view, which can combine text search, tags and other attribute filters
- Possibly fold tag search into this filter view, use an expandable header area
- for numeric files, support uspper / lower bounds
- for dates, support before / after
- for text, support contains / does not contain
- no need to support multiple filters on the same attribute, but could allow it if makes filtering more general
- example filter tasks are "BPM greater than X and less than Y", "Play count less then X", "Last Played date before X"
- Once done, may want a way to save / load named filters

### External Soundcard Support
- Route main and preview to specific audio output devices
- Support USB soundcards (e.g. Traktor Audio 2)
- Would need AVAudioEngine output node configuration per device


## Low Priority / Low Difficulty

### Keyboard Shortcut Expansion
- Seek forward/back for preview
- Jump to cue in/out via keyboard
- Load selected library track into preview
- These shortcuts exist in menus but may need refinement


## Low Priority / Medium Difficulty

### Playlist Organization
- As playlist count grows, sidebar becomes hard to navigate
- Options: archive/active sections, document-based playlists, folders
- Deferred for now — revisit when list gets long

