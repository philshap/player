# Player - Remaining Tasks

Organized by difficulty and importance. See TASKS-DONE.md for completed work.


## High Priority

### playlist playback / UI refinement
- the playlist player only shows tracks while playing or paused. Insstead, when a playlist is
  loaded, it should show the track that will be played next
- when Stop is pressed, playback should be reset but the next track to play (the first playlist track)
- it might be nice to show the next track in buffer in the playback view, possibly just showing the cover art
- having next track / previous track / scrub start playback doesn't seem correct either. In most
  cases, the playlist will be playing, but if it's paused, it should stay paused
- if a track is playing in a playlist, its background shows its play status in all playlists.
  Instead this should only be shown in the currently playing playlist view

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

