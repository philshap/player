//
//  MainPlaybackController.swift
//  player
//

import AVFoundation
import Foundation
import Observation

/// Controls playlist playback on the main (left-channel) output.
///
/// Extends `PlaybackController` (single-track machinery) with:
///   - An ordered playlist (with reorder-aware observation of the owning model).
///   - A prefetch-and-chain mechanism for gapless track-to-track transitions.
///   - A configurable inter-track gap (with countdown state for the UI).
///   - Play-count tracking (increments `Track.playCount` once per actual playback).
///
/// ### Reliability design
/// Each track is fully pre-loaded into an `AVAudioPCMBuffer` before playback begins,
/// eliminating disk I/O on the audio render thread. While a track is playing, the next
/// track is loaded asynchronously on a background task. Once that buffer is ready it is
/// *chained* directly into the player node's buffer queue, so the transition between
/// tracks is gapless — no main-thread dispatch or disk access occurs at the boundary.
///
/// If the pre-fetch task does not complete before the current track ends (e.g. the
/// track was very short or the disk was slow), the controller falls back to loading
/// on demand to keep things working correctly.
@Observable
final class MainPlaybackController: PlaybackController {

    // MARK: - Playlist

    private(set) var playlist:          [Track] = []
    private(set) var currentTrackIndex: Int     = 0

    // MARK: - Inter-track Gap

    var gapDuration: TimeInterval = 0
    private(set) var isInGap:      Bool         = false
    private(set) var gapRemaining: TimeInterval = 0

    @ObservationIgnored private var gapTimer: Timer?

    // MARK: - Play-Count Tracking

    /// Set to `true` once the current track's play has been recorded. Reset when a new
    /// track starts. Prevents the same track being counted more than once regardless of
    /// how many completion callbacks fire.
    @ObservationIgnored private var currentTrackPlayRecorded = false

    // MARK: - Pre-fetch & Seamless Chaining

    /// Buffer loaded ahead of time for the upcoming track.
    @ObservationIgnored private var preloadedBuffer:      AVAudioPCMBuffer?
    @ObservationIgnored private var preloadedBufferIndex: Int               = -1

    /// Background task that loads the next track's buffer.
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    /// Index of the track whose buffer has already been appended to the player node
    /// queue (via `audioEngine.chain(...)`). Non-nil means the transition will be gapless.
    @ObservationIgnored private var chainedNextIndex: Int?

    /// The buffer that was chained for the next track; becomes `currentFullBuffer`
    /// when `transitionToChained` runs.
    @ObservationIgnored private var chainedBuffer: AVAudioPCMBuffer?

    // MARK: - Init

    init(audioEngine: AudioEngineManager) {
        super.init(audioEngine: audioEngine, outputChannel: .left)
        startTrackObservation()
    }

    deinit {
        if let obs = playlistChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        bufferedTrackObservation?.cancel()
        prefetchTask?.cancel()
        gapTimer?.invalidate()
    }

    // MARK: - Playlist Loading

    func loadPlaylist(_ playlistModel: Playlist) {
        stop()
        activePlaylistModel = playlistModel
        playlist = playlistModel.orderedTracks
        startPlaylistChangeObserver()
    }

    func loadTracks(_ tracks: [Track]) {
        stop()
        activePlaylistModel = nil
        startPlaylistChangeObserver()
        playlist = tracks
    }

    // MARK: - Transport

    func play(from index: Int = 0) {
        guard !playlist.isEmpty else { return }
        playTrack(at: index.clamped(to: 0...(playlist.count - 1)))
    }

    override func resume() {
        // Preserve the old behavior: if no track is loaded but the playlist has
        // tracks, start from the top instead of being a no-op.
        if currentTrack == nil, !isPlaying, !playlist.isEmpty {
            play()
            return
        }
        super.resume()
    }

    /// Full reset — matches the pre-refactor behavior of `MainPlaybackController.stop`.
    override func stop() {
        cancelGap()
        cancelPrefetch()
        cancelChain()
        reset()
        currentTrackIndex = 0
    }

    func nextTrack() {
        cancelGap()
        if currentTrack == nil {
            if !playlist.isEmpty { play() }
            return
        }
        let next = currentTrackIndex + 1
        guard next < playlist.count else { stop(); return }
        playTrack(at: next)
    }

    func previousTrack() {
        if currentTrack == nil {
            if !playlist.isEmpty { play() }
            return
        }
        playTrack(at: max(currentTrackIndex - 1, 0))
    }

    // MARK: - Playlist-aware playTrack

    /// Starts playback of the track at `index`, using any prefetched buffer if available.
    private func playTrack(at index: Int) {
        guard index >= 0 && index < playlist.count else { return }

        recordPlayIfNeeded()

        // Claim the preloaded buffer before cancelPrefetch() wipes it.
        let cachedBuffer: AVAudioPCMBuffer? = (preloadedBufferIndex == index) ? preloadedBuffer : nil

        currentTrackIndex        = index
        currentTrackPlayRecorded = false

        playTrack(playlist[index], cachedBuffer: cachedBuffer)
    }

    // MARK: - Overridden Hooks

    override func willStartTrack(_ track: Track, generation: Int) {
        cancelPrefetch()
        cancelChain()
    }

    override func didStartTrack(_ track: Track, generation: Int) {
        prefetchAndChain(nextIndex: currentTrackIndex + 1, generation: generation)
    }

    /// Called when the current buffer — or a chained buffer — has finished playing.
    override func onTrackCompletion(generation: Int) {
        guard playbackGeneration == generation else { return }

        if let chainedIdx = chainedNextIndex {
            // The next track is already playing seamlessly; just update state.
            transitionToChained(index: chainedIdx, generation: generation)
        } else {
            autoAdvance()
        }
    }

    // MARK: - Chained Transition

    /// Transitions controller state to a track that is already playing (chained).
    /// Preserves the current `playbackGeneration` so the chained track's completion
    /// callback will also be processed correctly.
    private func transitionToChained(index: Int, generation: Int) {
        recordPlayIfNeeded()

        chainedNextIndex     = nil
        currentFullBuffer    = chainedBuffer   // promote the chained buffer for seeking
        chainedBuffer        = nil
        preloadedBuffer      = nil
        preloadedBufferIndex = -1

        let track                = playlist[index]
        currentTrackIndex        = index
        currentTrack             = track
        duration                 = effectiveDuration(for: track)
        currentTime              = 0
        currentTrackPlayRecorded = false

        // The player node's sample counter accumulates across chained buffers — it is
        // never reset by a stop/play cycle because chaining doesn't stop the node.
        // Store the node's current position as a negative offset so updatePosition()
        // computes time relative to THIS track's start rather than the session start.
        let sampleRate = sampleRate()
        if let pos = playbackPosition() {
            seekFrameOffset = -AVAudioFramePosition(pos * sampleRate)
        } else {
            seekFrameOffset = 0
        }

        // Keep playbackGeneration unchanged: the chained track's completion handler
        // was registered with the same generation value.

        prefetchAndChain(nextIndex: index + 1, generation: generation)
    }

    // MARK: - Auto-Advance

    /// Auto-advances after a track ends naturally (no chained successor).
    private func autoAdvance() {
        // Re-read the authoritative playlist from the model before deciding what to do.
        // Guards against the notification handler and the audio completion callback
        // racing on the main thread.
        if let model = activePlaylistModel {
            let fresh = model.orderedTracks
            playlist = fresh
            if let currentID = currentTrack?.id,
               let newIndex = fresh.firstIndex(where: { $0.id == currentID }) {
                currentTrackIndex = newIndex
            }
        }

        let next = currentTrackIndex + 1
        if next < playlist.count {
            if gapDuration > 0 {
                startGap(nextIndex: next)
            } else {
                playTrack(at: next)
            }
        } else {
            recordPlayIfNeeded()
            isPlaying    = false
            currentTrack = nil
            stopPositionTimer()
        }
    }

    // MARK: - Inter-track Gap

    private func startGap(nextIndex: Int) {
        recordPlayIfNeeded()
        stopPlayer()
        isPlaying = false
        stopPositionTimer()

        isInGap      = true
        gapRemaining = gapDuration

        let gapGen = playbackGeneration
        gapTimer   = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.playbackGeneration == gapGen else { timer.invalidate(); return }

            self.gapRemaining = max(0, self.gapRemaining - 0.1)
            if self.gapRemaining <= 0 {
                timer.invalidate()
                self.isInGap      = false
                self.gapRemaining = 0
                self.playTrack(at: nextIndex)
            }
        }
    }

    private func cancelGap() {
        gapTimer?.invalidate()
        gapTimer    = nil
        isInGap      = false
        gapRemaining = 0
    }

    // MARK: - Play Count Tracking

    private func recordPlayIfNeeded() {
        guard let track = currentTrack, !currentTrackPlayRecorded else { return }
        currentTrackPlayRecorded = true
        track.playCount      += 1
        track.lastPlayedDate  = Date()
    }

    // MARK: - Prefetch & Chain

    /// Loads the next track in the background and, once ready, appends its buffer
    /// directly to the player-node queue for a gapless transition.
    ///
    /// The buffer is also stored as `preloadedBuffer` so that `playTrack(at:)` can use
    /// it as a cache even if chaining isn't possible (e.g. a gap is configured or the
    /// user skips tracks).
    private func prefetchAndChain(nextIndex: Int, generation: Int) {
        guard nextIndex < playlist.count else { return }

        // Capture URL, format, channel, and track info on the main actor before entering the background task.
        let nextTrack = playlist[nextIndex]
        let url       = nextTrack.accessibleURL(libraryFolderURL: libraryFolderURL)
        let format    = audioEngine.playerFormat!
        let channel   = outputChannel

        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Load the FULL buffer
                let fullBuffer = try AudioEngineManager.loadBuffer(
                    url: url,
                    outputChannel: channel,
                    playerFormat: format
                )

                await MainActor.run {
                    // Discard if the user has already moved on.
                    guard self.playbackGeneration == generation,
                          !Task.isCancelled else { return }

                    // Slice for cue points
                    let sampleRate = self.sampleRate()
                    guard let playBuffer = self.sliceForCuePoints(fullBuffer, track: nextTrack, sampleRate: sampleRate) else {
                        return
                    }

                    // Always cache the FULL buffer so playTrack can use it on demand.
                    self.preloadedBuffer      = fullBuffer
                    self.preloadedBufferIndex = nextIndex

                    // Chain only when no gap is configured, the player is running,
                    // and we haven't already chained something.
                    guard self.gapDuration <= 0,
                          self.isPlaying,
                          self.chainedNextIndex == nil else { return }

                    self.chain(playBuffer) { [weak self] in
                        self?.handleTrackCompletion(generation: generation)
                    }
                    self.chainedBuffer    = fullBuffer  // Store full buffer for seeking
                    self.chainedNextIndex = nextIndex
                }
            } catch {
                // Prefetch failed; playTrack will load on demand when needed.
            }
        }
    }

    private func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask         = nil
        preloadedBuffer      = nil
        preloadedBufferIndex = -1
    }

    private func cancelChain() {
        chainedNextIndex = nil
        // Note: we do NOT dequeue the chained buffer from the player node here.
        // If the player is stopped (e.g. stop()/seek()) the buffer queue is cleared
        // automatically by AVAudioPlayerNode.stop().
    }

    // MARK: - Playlist Model Observation

    @ObservationIgnored private var activePlaylistModel: Playlist?
    @ObservationIgnored private var playlistChangeObserver: NSObjectProtocol?

    private func startPlaylistChangeObserver() {
        if let obs = playlistChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            playlistChangeObserver = nil
        }
        guard activePlaylistModel != nil else { return }
        playlistChangeObserver = NotificationCenter.default.addObserver(
            forName: .playlistDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let playlistID = notification.userInfo?["playlistID"] as? UUID,
                  playlistID == self.activePlaylistModel?.id else { return }
            self.syncPlaylistFromModel()
        }
    }

    private func syncPlaylistFromModel() {
        guard let model = activePlaylistModel else { return }
        let newTracks = model.orderedTracks
        playlist = newTracks

        if let currentID = currentTrack?.id,
           let newIndex = newTracks.firstIndex(where: { $0.id == currentID }) {
            currentTrackIndex = newIndex
        }

        // Revalidate or cancel the buffered track.
        handleBufferedTrackChanged()

        // If playing past the old end of the playlist and new tracks are now available,
        // start prefetching so the transition can be gapless.
        if isPlaying, preloadedBufferIndex < 0, chainedNextIndex == nil {
            let nextIndex = currentTrackIndex + 1
            if nextIndex < playlist.count {
                prefetchAndChain(nextIndex: nextIndex, generation: playbackGeneration)
            }
        }
    }

    // MARK: - Track & Playlist Change Observation

    /// Observation tracking for the buffered next track
    @ObservationIgnored private var bufferedTrackObservation: Task<Void, Never>?

    /// Cached state to detect actual changes (not just re-observation)
    @ObservationIgnored private var lastObservedBufferedTrackID: UUID?
    @ObservationIgnored private var lastObservedCuePoints: (cueIn: TimeInterval?, cueOut: TimeInterval?)?
    @ObservationIgnored private var lastObservedCurrentTrackID: UUID?
    @ObservationIgnored private var lastObservedBufferedIndex: Int?

    /// Starts observing changes to the prefetched next track using Swift Observation
    private func startTrackObservation() {
        // Start a background task that sets up observation tracking
        bufferedTrackObservation = Task { @MainActor in
            while !Task.isCancelled {
                await observeBufferedTrack()
            }
        }
    }

    /// Observes the buffered track using withObservationTracking
    @MainActor
    private func observeBufferedTrack() async {
        // Wait for a change to be detected
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                // Access the properties we want to observe
                // This registers them with the observation system

                // Observe current track (to detect when its position changes)
                if let current = currentTrack {
                    _ = current.id
                }

                // Observe buffered track's cue points
                if let bufferedIndex = chainedNextIndex ?? (preloadedBufferIndex >= 0 ? preloadedBufferIndex : nil),
                   bufferedIndex < playlist.count {
                    let track = playlist[bufferedIndex]
                    // Access the properties to register observation
                    _ = track.cuePointIn
                    _ = track.cuePointOut
                    _ = track.id
                }

                // Observe the playlist array - access individual track IDs to detect reordering
                _ = playlist.count
                for track in playlist {
                    _ = track.id
                }
            } onChange: {
                // This closure is called when any observed property changes
                Task { @MainActor in
                    self.handleBufferedTrackChanged()
                    continuation.resume()
                }
            }
        }
    }

    /// Called when the buffered track or playlist changes
    @MainActor
    private func handleBufferedTrackChanged() {
        // No buffered track to monitor
        guard preloadedBufferIndex >= 0 || chainedNextIndex != nil else {
            // Clear cached state
            lastObservedBufferedTrackID = nil
            lastObservedCuePoints = nil
            lastObservedCurrentTrackID = nil
            lastObservedBufferedIndex = nil
            return
        }

        let bufferedIndex = chainedNextIndex ?? preloadedBufferIndex

        // Check if buffered track is out of range
        guard bufferedIndex >= 0 && bufferedIndex < playlist.count else {
            print("[MainPlaybackController] Buffered track out of range, canceling")
            if chainedNextIndex != nil {
                cancelChain()
            } else {
                cancelPrefetch()
            }
            lastObservedBufferedTrackID = nil
            lastObservedCuePoints = nil
            lastObservedCurrentTrackID = nil
            lastObservedBufferedIndex = nil
            return
        }

        let bufferedTrack = playlist[bufferedIndex]
        let currentCuePoints = (cueIn: bufferedTrack.cuePointIn, cueOut: bufferedTrack.cuePointOut)

        // First time observing - just cache the state without invalidating
        guard let lastBufferedID = lastObservedBufferedTrackID,
              let lastCurrentID = lastObservedCurrentTrackID else {
            lastObservedBufferedTrackID = bufferedTrack.id
            lastObservedCuePoints = currentCuePoints
            lastObservedCurrentTrackID = currentTrack?.id
            lastObservedBufferedIndex = bufferedIndex
            return
        }

        // Check what actually changed
        let currentTrackChanged = lastCurrentID != currentTrack?.id
        let bufferedTrackChanged = lastBufferedID != bufferedTrack.id

        // If ONLY the current track changed (normal playback transition), update cache without invalidating
        // The buffered track should remain the same during normal transitions
        if currentTrackChanged && !bufferedTrackChanged {
            // Normal playback: current track advanced, buffered track is now playing
            // Just update the cached current track ID
            lastObservedCurrentTrackID = currentTrack?.id
            return
        }

        // Now check for actual issues that require invalidation
        var needsInvalidation = false
        var changeReason = ""

        // Determine what the buffered index SHOULD be based on the current track's position in playlist
        if let currentTrackID = currentTrack?.id,
           let actualCurrentIndex = playlist.firstIndex(where: { $0.id == currentTrackID }) {

            let expectedBufferedIndex = actualCurrentIndex + 1

            // The buffered index doesn't match what we expect
            if bufferedIndex != expectedBufferedIndex {
                // This means the playlist was reordered or the current track moved
                needsInvalidation = true
                changeReason = "playlist reordered: current track now at index \(actualCurrentIndex), buffered should be \(expectedBufferedIndex) but is \(bufferedIndex)"
            }
            // The buffered track's identity changed (track at that index was replaced)
            else if bufferedTrackChanged {
                needsInvalidation = true
                changeReason = "track at index \(bufferedIndex) was replaced"
            }
            // Cue points changed on the buffered track
            else if let lastCuePoints = lastObservedCuePoints,
                    (lastCuePoints.cueIn != currentCuePoints.cueIn || lastCuePoints.cueOut != currentCuePoints.cueOut) {
                needsInvalidation = true
                changeReason = "cue points changed on buffered track"
            }
        }

        // Update cached state
        lastObservedBufferedTrackID = bufferedTrack.id
        lastObservedCuePoints = currentCuePoints
        lastObservedCurrentTrackID = currentTrack?.id
        lastObservedBufferedIndex = bufferedIndex

        // Only invalidate if something actually changed that affects playback
        if needsInvalidation {
            print("[MainPlaybackController] Buffered track invalidated: \(changeReason)")

            if chainedNextIndex != nil {
                cancelChain()
            } else {
                cancelPrefetch()
            }

            // Restart prefetch with the correct next track
            if isPlaying, let currentIndex = playlist.firstIndex(where: { $0.id == currentTrack?.id }) {
                let nextIndex = currentIndex + 1
                if nextIndex < playlist.count {
                    prefetchAndChain(nextIndex: nextIndex, generation: playbackGeneration)
                }
            }
        }
    }
}
