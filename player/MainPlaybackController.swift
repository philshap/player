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
///   - Background pre-fetch of the next track's buffer for low-latency transitions.
///   - A configurable inter-track gap (with countdown state for the UI).
///   - Play-count tracking (increments `Track.playCount` once per actual playback).
///
/// ### Reliability design
/// Each track is fully pre-loaded into an `AVAudioPCMBuffer` before playback begins,
/// eliminating disk I/O on the audio render thread. While a track is playing, the next
/// track is loaded asynchronously on a background task so that auto-advance is instant:
/// the pre-loaded buffer is scheduled directly without a disk read.
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

    // MARK: - Pre-fetch

    /// Buffer loaded ahead of time for the upcoming track.
    @ObservationIgnored private var preloadedBuffer:      AVAudioPCMBuffer?
    @ObservationIgnored private var preloadedBufferIndex: Int               = -1
    @ObservationIgnored private var preloadedTrackID:     UUID?

    /// Background task that loads the next track's buffer.
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

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
        playlist = playlistModel.tracks
        startPlaylistChangeObserver()
        preloadFirstTrack()
    }

    func loadTracks(_ tracks: [Track]) {
        stop()
        activePlaylistModel = nil
        startPlaylistChangeObserver()
        playlist = tracks
        preloadFirstTrack()
    }

    /// Loads track 0 into the audio buffer without starting playback so that the
    /// first press of play is instant.
    private func preloadFirstTrack() {
        guard !playlist.isEmpty else { return }
        playTrack(playlist[0], startPlayback: false)
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

    /// Full reset — clears playback state, rewinds to track 0, and preloads it so
    /// the next play() starts instantly.
    override func stop() {
        cancelGap()
        cancelPrefetch()
        reset()
        currentTrackIndex = 0
        preloadFirstTrack()
    }

    func nextTrack() {
        cancelGap()
        refreshPlaylistFromActiveModel()
        if currentTrack == nil {
            if !playlist.isEmpty { play() }
            return
        }
        let wasPlaying = isPlaying
        let next = currentTrackIndex + 1
        guard next < playlist.count else { stop(); return }
        playTrack(at: next, startPlayback: wasPlaying)
    }

    func previousTrack() {
        refreshPlaylistFromActiveModel()
        if currentTrack == nil {
            if !playlist.isEmpty { play() }
            return
        }
        let wasPlaying = isPlaying
        playTrack(at: max(currentTrackIndex - 1, 0), startPlayback: wasPlaying)
    }

    // MARK: - Playlist-aware playTrack

    /// Loads the track at `index`, using any prefetched buffer if available.
    /// When `startPlayback` is false the track is parked at position 0 so that
    /// a subsequent `resume()` begins without reloading (preserves pause state).
    private func playTrack(at index: Int, startPlayback: Bool = true) {
        guard index >= 0 && index < playlist.count else { return }

        recordPlayIfNeeded()
        let targetTrack = playlist[index]

        // Claim the preloaded buffer before cancelPrefetch() wipes it.
        let cachedBuffer: AVAudioPCMBuffer? =
            (preloadedBufferIndex == index && preloadedTrackID == targetTrack.id) ? preloadedBuffer : nil

        currentTrackIndex        = index
        currentTrackPlayRecorded = false

        playTrack(targetTrack, cachedBuffer: cachedBuffer, startPlayback: startPlayback)
    }

    // MARK: - Overridden Hooks

    override func willStartTrack(_ track: Track, generation: Int) {
        cancelPrefetch()
    }

    override func didStartTrack(_ track: Track, generation: Int) {
        prefetchNext(index: currentTrackIndex + 1, generation: generation)
    }

    override func onTrackCompletion(generation: Int) {
        guard playbackGeneration == generation else { return }
        autoAdvance()
    }

    // MARK: - Auto-Advance

    /// Auto-advances after a track ends naturally.
    private func autoAdvance() {
        // Re-read the authoritative playlist before deciding what to do.
        // Guards against races between model notifications and completion callbacks.
        refreshPlaylistFromActiveModel()

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

    // MARK: - Pre-fetch

    /// Loads the next track's buffer in the background so that auto-advance can
    /// schedule it immediately without a disk read.
    private func prefetchNext(index nextIndex: Int, generation: Int) {
        guard nextIndex < playlist.count else { return }

        // Capture track info on the main actor before entering the background task.
        let nextTrack = playlist[nextIndex]
        let url       = nextTrack.accessibleURL(libraryFolderURL: libraryFolderURL)
        let format    = audioEngine.playerFormat!
        let channel   = outputChannel

        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let fullBuffer = try AudioEngineManager.loadBuffer(
                    url: url,
                    outputChannel: channel,
                    playerFormat: format
                )

                await MainActor.run {
                    guard self.playbackGeneration == generation,
                          !Task.isCancelled else { return }

                    self.preloadedBuffer      = fullBuffer
                    self.preloadedBufferIndex = nextIndex
                    self.preloadedTrackID     = nextTrack.id
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
        preloadedTrackID     = nil
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
        let newTracks = model.tracks
        playlist = newTracks

        if let currentID = currentTrack?.id,
           let newIndex = newTracks.firstIndex(where: { $0.id == currentID }) {
            currentTrackIndex = newIndex
        }

        // Revalidate or cancel any stale prefetched buffer.
        handleBufferedTrackChanged()

        // If no prefetch is running and a next track is now available, start one.
        if isPlaying, preloadedBufferIndex < 0, prefetchTask == nil {
            let nextIndex = currentTrackIndex + 1
            if nextIndex < playlist.count {
                prefetchNext(index: nextIndex, generation: playbackGeneration)
            }
        }
    }

    /// Synchronously refreshes playlist order/index from the authoritative model.
    /// Used by manual transport actions so they see reorder changes immediately,
    /// even if a notification is still queued on the run loop.
    private func refreshPlaylistFromActiveModel() {
        guard let model = activePlaylistModel else { return }
        playlist = model.tracks
        if let currentID = currentTrack?.id,
           let newIndex = playlist.firstIndex(where: { $0.id == currentID }) {
            currentTrackIndex = newIndex
        }
    }

    // MARK: - Buffered-Track Observation

    @ObservationIgnored private var bufferedTrackObservation: Task<Void, Never>?

    /// Cached cue points of the prefetched track — used to detect edits without
    /// triggering false positives on each observation re-registration.
    @ObservationIgnored private var lastObservedCuePoints: (cueIn: TimeInterval?, cueOut: TimeInterval?)?

    private func startTrackObservation() {
        bufferedTrackObservation = Task { @MainActor in
            while !Task.isCancelled {
                await observeBufferedTrack()
            }
        }
    }

    @MainActor
    private func observeBufferedTrack() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                if let current = currentTrack { _ = current.id }

                if preloadedBufferIndex >= 0, preloadedBufferIndex < playlist.count {
                    let track = playlist[preloadedBufferIndex]
                    _ = track.cuePointIn
                    _ = track.cuePointOut
                    _ = track.id
                }

                _ = playlist.count
                for track in playlist { _ = track.id }
            } onChange: {
                Task { @MainActor in
                    self.handleBufferedTrackChanged()
                    continuation.resume()
                }
            }
        }
    }

    /// Validates the prefetched buffer against the current playlist and cancels it
    /// if it no longer matches the correct next track.
    @MainActor
    private func handleBufferedTrackChanged() {
        guard preloadedBufferIndex >= 0 else {
            lastObservedCuePoints = nil
            return
        }

        guard preloadedBufferIndex < playlist.count else {
            // Buffered index fell out of range after a deletion.
            lastObservedCuePoints = nil
            invalidateBufferedState()
            return
        }

        let bufferedTrack    = playlist[preloadedBufferIndex]
        let currentCuePoints = (cueIn: bufferedTrack.cuePointIn, cueOut: bufferedTrack.cuePointOut)

        // Track ID mismatch: the track at the buffered slot changed.
        let trackMismatch = preloadedTrackID != nil && bufferedTrack.id != preloadedTrackID

        // Index mismatch: prefetched slot is no longer current+1.
        var indexMismatch = false
        if let currentID = currentTrack?.id,
           let currentIndex = playlist.firstIndex(where: { $0.id == currentID }) {
            indexMismatch = (preloadedBufferIndex != currentIndex + 1)
        }

        // Cue-point edit on the (still-correct) buffered track.
        let cuePointsChanged: Bool
        if !trackMismatch, !indexMismatch, let last = lastObservedCuePoints {
            cuePointsChanged = last.cueIn != currentCuePoints.cueIn || last.cueOut != currentCuePoints.cueOut
        } else {
            cuePointsChanged = false
        }
        lastObservedCuePoints = currentCuePoints

        if trackMismatch || indexMismatch || cuePointsChanged {
            invalidateBufferedState()
        }
    }

    private func invalidateBufferedState() {
        cancelPrefetch()
        guard isPlaying,
              let currentID = currentTrack?.id,
              let currentIndex = playlist.firstIndex(where: { $0.id == currentID }) else { return }
        let nextIndex = currentIndex + 1
        guard nextIndex < playlist.count else { return }
        prefetchNext(index: nextIndex, generation: playbackGeneration)
    }
}
