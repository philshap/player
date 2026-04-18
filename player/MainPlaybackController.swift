//
//  MainPlaybackController.swift
//  player
//

import AVFoundation
import Foundation
import Observation

/// Controls playlist playback on the main (left-channel) output.
///
/// ### Reliability design
/// Each track is fully pre-loaded into an `AVAudioPCMBuffer` before playback begins,
/// eliminating disk I/O on the audio render thread. While a track is playing, the next
/// track is loaded asynchronously on a background task. Once that buffer is ready it is
/// *chained* directly into the player node's buffer queue, so the transition between
/// tracks is gapless — no main-thread dispatch or disk access occurs at the boundary.
///
/// If the pre-fetch task does not complete before the current track ends (e.g. the
/// track was very short or the disk was slow), the controller falls back to a
/// synchronous load in `playTrack(at:)` to keep things working correctly.
@Observable
final class MainPlaybackController {

    // MARK: - Dependencies

    private let audioEngine: AudioEngineManager

    // MARK: - Observable State

    private(set) var playlist:           [Track]        = []
    private(set) var currentTrack:       Track?
    private(set) var currentTrackIndex:  Int            = 0
    private(set) var isPlaying:          Bool           = false
    private(set) var currentTime:        TimeInterval   = 0
    private(set) var duration:           TimeInterval   = 0

    // MARK: - Inter-track Gap

    var gapDuration: TimeInterval = 0
    private(set) var isInGap:      Bool           = false
    private(set) var gapRemaining: TimeInterval   = 0

    // MARK: - Internal Playback State

    private var seekFrameOffset:       AVAudioFramePosition = 0
    private var positionTimer:         Timer?
    private var gapTimer:              Timer?
    /// Cancellable task for background buffer loads during seek.
    private var seekTask:              Task<Void, Never>?

    /// Incremented on every play/seek/stop so stale completion callbacks are discarded.
    private var playbackGeneration:    Int  = 0

    /// Set to `true` once the current track's play has been recorded. Reset when a new
    /// track starts. Prevents the same track being counted more than once regardless of
    /// how many completion callbacks fire.
    private var currentTrackPlayRecorded = false

    // MARK: - Pre-fetch & Seamless Chaining

    /// Full decoded buffer for the current track — kept in memory so seeks can
    /// slice it without re-reading from disk or resolving bookmarks.
    private var currentFullBuffer:    AVAudioPCMBuffer?

    /// Buffer loaded ahead of time for the upcoming track.
    private var preloadedBuffer:      AVAudioPCMBuffer?
    private var preloadedBufferIndex: Int               = -1

    /// Background task that loads the next track's buffer.
    private var prefetchTask:         Task<Void, Never>?

    /// Index of the track whose buffer has already been appended to the player node
    /// queue (via `audioEngine.chainMain`). Non-nil means the transition will be gapless.
    private var chainedNextIndex:     Int?

    /// The buffer that was chained for the next track; becomes `currentFullBuffer`
    /// when `transitionToChained` runs.
    private var chainedBuffer:        AVAudioPCMBuffer?

    // MARK: - Init

    /// Set by AppState when a library folder is opened.
    var libraryFolderURL: URL?

    init(audioEngine: AudioEngineManager) {
        self.audioEngine = audioEngine
    }

    deinit {
        prefetchTask?.cancel()
        positionTimer?.invalidate()
        gapTimer?.invalidate()
    }

    // MARK: - Playlist Loading

    func loadPlaylist(_ playlistModel: Playlist) {
        stop()
        playlist = playlistModel.orderedTracks
    }

    func loadTracks(_ tracks: [Track]) {
        stop()
        playlist = tracks
    }

    // MARK: - Transport Controls

    func play(from index: Int = 0) {
        guard !playlist.isEmpty else { return }
        playTrack(at: index.clamped(to: 0...(playlist.count - 1)))
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        guard isPlaying else { return }
        audioEngine.pauseMain()
        isPlaying = false
        stopPositionTimer()
    }

    func resume() {
        guard !isPlaying else { return }
        guard currentTrack != nil else {
            if !playlist.isEmpty { play() }
            return
        }
        audioEngine.resumeMain()
        isPlaying = true
        startPositionTimer()
    }

    func stop() {
        cancelGap()
        cancelPrefetch()
        cancelChain()
        seekTask?.cancel()
        seekTask = nil
        playbackGeneration += 1
        audioEngine.stopMain()
        currentFullBuffer  = nil
        isPlaying          = false
        currentTrack       = nil
        currentTrackIndex  = 0
        currentTime        = 0
        duration           = 0
        seekFrameOffset    = 0
        stopPositionTimer()
    }

    func nextTrack() {
        cancelGap()
        guard currentTrack != nil else {
            if !playlist.isEmpty { play() }
            return
        }
        let next = currentTrackIndex + 1
        guard next < playlist.count else { stop(); return }
        playTrack(at: next)
    }

    func previousTrack() {
        guard currentTrack != nil else {
            if !playlist.isEmpty { play() }
            return
        }
        if currentTime > 3.0 {
            seek(to: 0)
            return
        }
        playTrack(at: max(currentTrackIndex - 1, 0))
    }

    func seek(to time: TimeInterval) {
        guard let track = currentTrack else { return }

        cancelPrefetch()
        cancelChain()
        seekTask?.cancel()
        seekTask = nil

        let clamped     = time.clamped(to: 0...duration)
        let sampleRate  = audioEngine.mainSampleRate()
        let targetFrame = AVAudioFramePosition(clamped * sampleRate)

        seekFrameOffset    = targetFrame
        playbackGeneration += 1
        let gen            = playbackGeneration

        currentTime = clamped
        isPlaying   = false
        stopPositionTimer()

        if let buf = currentFullBuffer, let slice = buf.sliced(fromFrame: targetFrame) {
            // Fast path: slice the in-memory buffer — no disk access, no bookmark resolution.
            do {
                try audioEngine.scheduleSeekMain(slice) { [weak self] in
                    self?.handleTrackCompletion(generation: gen)
                }
                isPlaying = true
                startPositionTimer()
                prefetchAndChain(nextIndex: currentTrackIndex + 1, generation: gen)
            } catch {
                print("MainPlaybackController: seek error — \(error.localizedDescription)")
            }
            return
        }

        // Slow path: full buffer not available yet (shouldn't happen during normal playback,
        // but guards against seeking before the initial load completes).
        let url           = track.accessibleURL(libraryFolderURL: libraryFolderURL)
        let outputChannel = audioEngine.mainOutputChannel
        guard let format  = audioEngine.playerFormat else { return }
        audioEngine.stopMain()

        seekTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let buffer = try AudioEngineManager.loadBuffer(
                    url: url, fromFrame: targetFrame, outputChannel: outputChannel, playerFormat: format)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled,
                          self.playbackGeneration == gen else { return }
                    do {
                        try self.audioEngine.scheduleSeekMain(buffer) { [weak self] in
                            self?.handleTrackCompletion(generation: gen)
                        }
                        self.currentFullBuffer = buffer
                        self.isPlaying = true
                        self.startPositionTimer()
                        self.prefetchAndChain(nextIndex: self.currentTrackIndex + 1, generation: gen)
                    } catch {
                        print("MainPlaybackController: seek error — \(error.localizedDescription)")
                    }
                }
            } catch { }
        }
    }

    // MARK: - Private Playback

    private func playTrack(at index: Int) {
        guard index >= 0 && index < playlist.count else { return }

        recordPlayIfNeeded()
        seekTask?.cancel()
        seekTask = nil
        cancelPrefetch()
        cancelChain()

        let track = playlist[index]
        playbackGeneration += 1
        let gen           = playbackGeneration
        seekFrameOffset   = 0
        currentTrackIndex = index
        currentTrack      = track
        currentTrackPlayRecorded = false
        duration          = track.duration
        currentTime       = 0

        do {
            // Use the pre-loaded buffer when available; otherwise load synchronously.
            // For small files the synchronous path is fast (<50 ms); for the common
            // case the prefetch will have the buffer ready before this is called.
            let buffer: AVAudioPCMBuffer
            if preloadedBufferIndex == index, let cached = preloadedBuffer {
                buffer             = cached
                preloadedBuffer    = nil
                preloadedBufferIndex = -1
            } else {
                buffer = try audioEngine.loadBufferForMain(url: track.accessibleURL(libraryFolderURL: libraryFolderURL))
            }

            try audioEngine.playMain(buffer) { [weak self] in
                self?.handleTrackCompletion(generation: gen)
            }
            currentFullBuffer = buffer
            isPlaying = true
            startPositionTimer()
            prefetchAndChain(nextIndex: index + 1, generation: gen)
        } catch {
            print("MainPlaybackController: playback error — \(error.localizedDescription)")
            isPlaying = false
        }
    }

    /// Loads the next track in the background and, once ready, appends its buffer
    /// directly to the player-node queue for a gapless transition.
    ///
    /// The buffer is also stored as `preloadedBuffer` so that `playTrack(at:)` can use
    /// it as a cache even if chaining isn't possible (e.g. a gap is configured or the
    /// user skips tracks).
    private func prefetchAndChain(nextIndex: Int, generation: Int) {
        guard nextIndex < playlist.count else { return }

        // Capture URL, format, and channel setting on the main actor before entering the background task.
        let url     = playlist[nextIndex].accessibleURL(libraryFolderURL: libraryFolderURL)
        let format  = audioEngine.playerFormat!
        let channel = audioEngine.mainOutputChannel

        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let buffer = try AudioEngineManager.loadBuffer(url: url, outputChannel: channel, playerFormat: format)

                await MainActor.run {
                    // Discard if the user has already moved on.
                    guard self.playbackGeneration == generation,
                          !Task.isCancelled else { return }

                    // Always cache the buffer so playTrack can use it on demand.
                    self.preloadedBuffer      = buffer
                    self.preloadedBufferIndex = nextIndex

                    // Chain only when no gap is configured, the player is running,
                    // and we haven't already chained something.
                    guard self.gapDuration <= 0,
                          self.isPlaying,
                          self.chainedNextIndex == nil else { return }

                    self.audioEngine.chainMain(buffer) { [weak self] in
                        self?.handleTrackCompletion(generation: generation)
                    }
                    self.chainedBuffer    = buffer
                    self.chainedNextIndex = nextIndex
                }
            } catch {
                // Prefetch failed; playTrack will load on demand when needed.
            }
        }
    }

    /// Called (on the main thread) when the current buffer — or a chained buffer — has
    /// finished playing back.
    private func handleTrackCompletion(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }

            if let chainedIdx = self.chainedNextIndex {
                // The next track is already playing seamlessly; just update state.
                self.transitionToChained(index: chainedIdx, generation: generation)
            } else {
                self.autoAdvance()
            }
        }
    }

    /// Transitions controller state to a track that is already playing (chained).
    /// Preserves the current `playbackGeneration` so the chained track's completion
    /// callback will also be processed correctly.
    private func transitionToChained(index: Int, generation: Int) {
        recordPlayIfNeeded()

        chainedNextIndex  = nil
        currentFullBuffer = chainedBuffer   // promote the chained buffer for seeking
        chainedBuffer     = nil

        let track             = playlist[index]
        currentTrackIndex     = index
        currentTrack          = track
        duration              = track.duration
        currentTime           = 0
        currentTrackPlayRecorded = false

        // The player node's sample counter accumulates across chained buffers — it is
        // never reset by a stop/play cycle because chaining doesn't stop the node.
        // Store the node's current position as a negative offset so updatePosition()
        // computes time relative to THIS track's start rather than the session start.
        let sampleRate = audioEngine.mainSampleRate()
        if let pos = audioEngine.mainPlaybackPosition() {
            seekFrameOffset = -AVAudioFramePosition(pos * sampleRate)
        } else {
            seekFrameOffset = 0
        }

        // Keep playbackGeneration unchanged: the chained track's completion handler
        // was registered with the same generation value.

        prefetchAndChain(nextIndex: index + 1, generation: generation)
    }

    /// Auto-advances after a track ends naturally (no chained successor).
    private func autoAdvance() {
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
        audioEngine.stopMain()
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

    // MARK: - Prefetch / Chain Cancellation

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

    // MARK: - Position Timer

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func updatePosition() {
        guard isPlaying else { return }

        if let position = audioEngine.mainPlaybackPosition() {
            let offsetSeconds = Double(seekFrameOffset) / audioEngine.mainSampleRate()
            let computed      = position + offsetSeconds
            currentTime       = max(0, min(computed, duration))

            if let cueOut = currentTrack?.cuePointOut, currentTime >= cueOut {
                autoAdvance()
            }
        } else if !audioEngine.isMainPlaying {
            // Engine stopped unexpectedly (e.g. audio device removed). Reflect that.
            isPlaying = false
        }
    }
}

