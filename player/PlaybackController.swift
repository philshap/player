//
//  PlaybackController.swift
//  player
//
//  Shared single-track playback machinery. Buffer-based playback with
//  cue-point-aware slicing, async loading, position tracking, and seeking.
//
//  Subclassed by:
//    - PreviewPlaybackController — adds bypassCuePoints, unload.
//    - MainPlaybackController    — adds playlist, prefetch/chain, gap, play counts.
//

import AVFoundation
import Foundation
import Observation
import os.log

private let seekLog = OSLog(subsystem: "com.player", category: "seek")

/// Controls playback on a single player-node + mixer pair.
///
/// Each controller owns its own `AVAudioPlayerNode` and `AVAudioMixerNode`; the shared
/// `AudioEngineManager` provides the `AVAudioEngine` instance, buffer format, serial
/// dispatch queue, and configuration-change handling. All transport methods call
/// directly onto this controller's own nodes.
///
/// ### Reliability design
/// Each track is fully decoded into an `AVAudioPCMBuffer` (in the background) before
/// playback begins, eliminating disk I/O on the audio render thread. Seeking slices
/// the in-memory buffer (a memcpy, ~1–2 ms) rather than re-reading the file.
///
/// If the buffer isn't yet loaded when a seek arrives, the controller falls back to
/// loading synchronously on a background task before applying the seek.
@Observable
class PlaybackController {

    // MARK: - Dependencies

    @ObservationIgnored let audioEngine: AudioEngineManager

    /// Set by AppState when a library folder is opened.
    @ObservationIgnored var libraryFolderURL: URL?

    // MARK: - Audio Graph (owned)

    @ObservationIgnored let player = AVAudioPlayerNode()
    @ObservationIgnored let mixer  = AVAudioMixerNode()

    /// Pending seek work item — cancelled when a newer seek arrives so rapid
    /// seeks (e.g. slider dragging) skip stale positions instead of queuing.
    /// Must only be accessed from the main thread.
    @ObservationIgnored private var pendingSeek: DispatchWorkItem?

    /// Monotonically increasing counter used to correlate seek log events.
    @ObservationIgnored private var seekSerial: Int = 0

    /// True while the user is actively dragging a seek slider.
    /// Intermediate seeks use prepareSeek only; player.play() is deferred to endInteractiveSeek().
    @ObservationIgnored private(set) var isInteractiveSeeking = false
    @ObservationIgnored private var interactiveSeekWasPlaying = false

    // MARK: - Observable State

    // Writable at module-internal scope so subclasses in other files can update them
    // (e.g. PreviewPlaybackController recomputes `duration` when cue-point bypass toggles,
    // MainPlaybackController mutates state during playlist transitions and chained
    // track hand-offs). External callers should treat these as read-only.
    var currentTrack: Track?
    var isPlaying:    Bool         = false
    var currentTime:  TimeInterval = 0
    var duration:     TimeInterval = 0

    /// Which output channel(s) newly loaded buffers will carry signal in.
    /// Changing this does not affect a currently-playing track until the next buffer loads.
    var outputChannel: AudioEngineManager.OutputChannel

    /// Output volume (0.0 ... 1.0) for this controller's mixer.
    var volume: Float {
        get { mixer.outputVolume }
        set { mixer.outputVolume = newValue.clamped(to: 0...1) }
    }

    // MARK: - Internal Playback State

    /// Time offset (seconds) at which the currently scheduled slice begins.
    /// Used to convert the player node's accumulated sample time into
    /// a track-relative `currentTime`.
    @ObservationIgnored var seekTimeOffset: TimeInterval = 0

    @ObservationIgnored var positionTimer: Timer?

    /// Full decoded buffer for the current track — kept in memory so seeks can
    /// slice it without re-reading from disk or resolving bookmarks.
    @ObservationIgnored var currentFullBuffer: AVAudioPCMBuffer?

    /// Cancellable background load task (initial load + slow-path seeks).
    @ObservationIgnored var loadTask: Task<Void, Never>?

    /// Incremented on every play/seek/stop so stale completion callbacks are discarded.
    @ObservationIgnored var playbackGeneration: Int = 0

    // MARK: - Init

    init(audioEngine: AudioEngineManager,
         outputChannel: AudioEngineManager.OutputChannel) {
        self.audioEngine   = audioEngine
        self.outputChannel = outputChannel
        audioEngine.attach(self, player: player, mixer: mixer)
    }

    deinit {
        loadTask?.cancel()
        positionTimer?.invalidate()
    }

    // MARK: - Overridable Hooks

    /// When `false`, cue points on tracks are ignored (plays the full file).
    /// PreviewPlaybackController overrides this via `bypassCuePoints`.
    var shouldApplyCuePoints: Bool { true }

    /// Called on the main thread when a track's buffer has finished playing.
    /// The generation matches the generation at schedule time — subclasses should
    /// only act if `self.playbackGeneration == generation`.
    ///
    /// Default behavior: stop playback. Subclasses (MainPlaybackController) override
    /// to auto-advance the playlist or transition to a chained next track.
    func onTrackCompletion(generation: Int) {
        guard playbackGeneration == generation else { return }
        isPlaying = false
        stopPositionTimer()
    }

    /// Called immediately before `playTrack` starts loading/scheduling a new track.
    /// Subclasses hook this to cancel pending work (prefetch, chain, gap).
    func willStartTrack(_ track: Track, generation: Int) {}

    /// Called on the main thread immediately after a new track's slice has been
    /// scheduled on the player. Use this to kick off post-start work (prefetching).
    func didStartTrack(_ track: Track, generation: Int) {}

    // MARK: - Transport Controls

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    /// Call when a seek slider drag begins.
    /// Pauses the player immediately and suppresses all audio-node operations for
    /// intermediate drag events. endInteractiveSeek() applies the final position once.
    func beginInteractiveSeek() {
        guard !isInteractiveSeeking else { return }
        isInteractiveSeeking = true
        interactiveSeekWasPlaying = isPlaying
        if isPlaying {
            isPlaying = false
            stopPositionTimer()
            audioEngine.playerQueue.async { [player] in
                player.pause()
            }
        }
    }

    /// Call when a seek slider drag ends.
    /// Applies the final seek position with a single stop+schedule+(play if needed).
    func endInteractiveSeek() {
        guard isInteractiveSeeking else { return }
        isInteractiveSeeking = false

        guard let track = currentTrack else { return }
        let finalPosition = currentTime

        loadTask?.cancel()
        loadTask = nil
        playbackGeneration += 1
        let gen = playbackGeneration
        seekTimeOffset = 0

        willStartTrack(track, generation: gen)

        if let fullBuffer = currentFullBuffer {
            applySlice(from: fullBuffer, track: track, position: finalPosition,
                       generation: gen, startPlayback: interactiveSeekWasPlaying)
        } else {
            loadBuffer(for: track, generation: gen) { [weak self] buffer in
                guard let self else { return }
                self.currentFullBuffer = buffer
                self.applySlice(from: buffer, track: track, position: finalPosition,
                                generation: gen, startPlayback: self.interactiveSeekWasPlaying)
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        stopPositionTimer()
        audioEngine.playerQueue.async { [player] in
            player.pause()
        }
    }

    func resume() {
        guard !isPlaying, currentTrack != nil else { return }
        isPlaying = true
        startPositionTimer()
        audioEngine.playerQueue.async { [player] in
            player.play()
        }
    }

    /// Stops playback and parks the buffer at position 0 so `resume()` works after.
    /// Retains `currentTrack` and `currentFullBuffer`.
    /// Subclasses can override to add extra cleanup (e.g. main clears playlist state).
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        playbackGeneration += 1
        isPlaying = false
        currentTime = 0
        seekTimeOffset = 0
        stopPositionTimer()
        // Park the buffer at position 0 so resume() works after stop.
        // Falls back to a plain stop when no buffer is loaded yet.
        if let fullBuffer = currentFullBuffer, let track = currentTrack {
            parkAtZero(fullBuffer: fullBuffer, track: track)
        } else {
            stopPlayer()
        }
    }

    /// Fully clears current track and buffer. Base for `unload()` / main's `stop()`.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        playbackGeneration += 1
        stopPlayer()
        currentFullBuffer = nil
        isPlaying         = false
        currentTrack      = nil
        currentTime       = 0
        duration          = 0
        seekTimeOffset   = 0
        stopPositionTimer()
    }

    func seek(to time: TimeInterval) {
        guard let track = currentTrack else { return }

        seekSerial += 1
        let serial = seekSerial

        let clamped = time.clamped(to: 0...duration)

        if isInteractiveSeeking {
            // During drag: the player is already paused by beginInteractiveSeek().
            // Just update the displayed position; endInteractiveSeek() will apply it once.
            currentTime = clamped
            return
        }

        let wasPlaying = isPlaying
        let hasCached = currentFullBuffer != nil

        loadTask?.cancel()
        loadTask = nil
        playbackGeneration += 1
        let gen = playbackGeneration

        currentTime = clamped
        isPlaying   = false
        stopPositionTimer()

        willStartTrack(track, generation: gen)  // give subclasses a chance to cancel prefetch/chain

        if let fullBuffer = currentFullBuffer {
            applySlice(from: fullBuffer, track: track, position: clamped, generation: gen, startPlayback: wasPlaying)
            return
        }

        // Slow path: buffer not yet loaded. Load in background, then seek.
        loadBuffer(for: track, generation: gen) { [weak self] buffer in
            guard let self else { return }
            self.currentFullBuffer = buffer
            // Re-evaluate: if resume() was called while the buffer was loading, honour it.
            let shouldPlay = wasPlaying || self.isPlaying
            self.applySlice(from: buffer, track: track, position: clamped, generation: gen, startPlayback: shouldPlay)
        }
    }

    // MARK: - Playback Entry Points

    /// Starts (or prepares without starting) playback of `track`.
    /// If `cachedBuffer` is non-nil it is used directly (fast path for prefetched
    /// buffers); otherwise the buffer is loaded asynchronously on a background task.
    /// When `startPlayback` is false the track is loaded and parked at position 0 so
    /// that a subsequent `resume()` begins immediately without reloading.
    func playTrack(_ track: Track, cachedBuffer: AVAudioPCMBuffer? = nil, startPlayback: Bool = true) {
        loadTask?.cancel()
        loadTask = nil
        playbackGeneration += 1
        let gen = playbackGeneration

        seekTimeOffset = 0
        currentTrack    = track
        duration        = effectiveDuration(for: track)
        currentTime     = 0

        willStartTrack(track, generation: gen)

        if let cached = cachedBuffer {
            // Fast path: buffer already in memory — schedule synchronously.
            // Only clear the player node when we're not starting playback (avoids
            // an unnecessary stop/restart in the playing case).
            if !startPlayback { stopPlayer() }
            currentFullBuffer = cached
            applySlice(from: cached, track: track, position: 0, generation: gen, startPlayback: startPlayback)
            return
        }

        // Slow path: buffer must be loaded from disk.
        // Stop the player node and halt the position timer so the old track's
        // accumulated time doesn't advance against the new track's duration.
        // isPlaying is intentionally NOT cleared here — it captures whether the
        // user wants playback, so next/previousTrack() can read wasPlaying correctly
        // even when a second navigation arrives while the first track is still loading.
        stopPlayer()
        stopPositionTimer()

        loadBuffer(for: track, generation: gen) { [weak self] buffer in
            guard let self else { return }
            self.currentFullBuffer = buffer
            // Re-evaluate: honour a resume() that arrived while we were loading.
            let shouldPlay = startPlayback || self.isPlaying
            self.applySlice(from: buffer, track: track, position: 0, generation: gen, startPlayback: shouldPlay)
        }
    }

    // MARK: - Cue Points

    func effectiveDuration(for track: Track) -> TimeInterval {
        guard shouldApplyCuePoints else { return track.duration }
        let cueIn  = track.cuePointIn ?? 0
        let cueOut = track.cuePointOut ?? track.duration
        return max(0, cueOut - cueIn)
    }

    func effectiveStartFrame(for track: Track, sampleRate: Double) -> AVAudioFramePosition {
        guard shouldApplyCuePoints else { return 0 }
        return track.cuePointIn.map { AVAudioFramePosition($0 * sampleRate) } ?? 0
    }

    func effectiveEndFrame(for track: Track, sampleRate: Double) -> AVAudioFramePosition? {
        guard shouldApplyCuePoints else { return nil }
        return track.cuePointOut.map { AVAudioFramePosition($0 * sampleRate) }
    }

    /// Slices `fullBuffer` to the playable range for `track` (cue-in..cue-out).
    /// Returns `nil` if the slice would be empty. Returns the full buffer unchanged
    /// when no cue points are configured or when cue points are bypassed.
    func sliceForCuePoints(_ fullBuffer: AVAudioPCMBuffer, track: Track, sampleRate: Double) -> AVAudioPCMBuffer? {
        let cueIn  = effectiveStartFrame(for: track, sampleRate: sampleRate)
        let cueOut = effectiveEndFrame(for: track, sampleRate: sampleRate)
        guard cueIn > 0 || cueOut != nil else { return fullBuffer }
        let end = cueOut ?? AVAudioFramePosition(fullBuffer.frameLength)
        let length = AVAudioFrameCount(end - cueIn)
        guard length > 0 else { return nil }
        return fullBuffer.sliced(fromFrame: cueIn, length: length)
    }

    // MARK: - Node Transport (own player)

    /// Stops the player node and cancels any pending seek. Does not mutate observable state.
    func stopPlayer() {
        pendingSeek?.cancel()
        pendingSeek = nil
        audioEngine.playerQueue.async { [player] in
            player.stop()
        }
    }

    /// Appends `buffer` to the player's queue WITHOUT stopping.
    /// The buffer plays seamlessly immediately after all currently-queued content.
    /// Call this while a track is already playing to achieve zero-gap transitions.
    func chain(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        audioEngine.playerQueue.async { [player] in
            Self.schedule(buffer, on: player, completion: completion)
        }
        // Do NOT call stop() or play() — the player is already running.
    }

    /// Schedules a pre-sliced buffer for seek playback.
    ///
    /// Cancels any pending seek work item before dispatching the new one, so rapid
    /// seeks (e.g. slider dragging) skip stale positions instead of queuing up.
    /// The buffer must already be sliced to start at the desired frame — no disk I/O.
    func scheduleSeek(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)? = nil) throws {
        let hadPending = pendingSeek != nil
        pendingSeek?.cancel()
        seekSerial += 1
        let serial = seekSerial
        try audioEngine.ensureRunning()
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [player] in
            guard !item.isCancelled else {
                return
            }
            let t0 = CACurrentMediaTime()
            player.stop()
            let stopMs = Int((CACurrentMediaTime() - t0) * 1000)
            Self.schedule(buffer, on: player, completion: completion)
            // A newer seek may have arrived while we were stopping. If so, skip play() —
            // the next item will stop() an idle player (fast) rather than a running one (slow).
            guard !item.isCancelled else {
                return
            }
            player.play()
        }
        pendingSeek = item
        audioEngine.playerQueue.async(execute: item)
    }

    /// Schedules `buffer` on the player without starting playback.
    /// Call `resume()` afterwards to begin playing from the prepared position.
    ///
    /// Uses the same `pendingSeek` cancellation mechanism as `scheduleSeek`, so rapid
    /// paused-seek events cancel earlier items rather than piling up on the audio queue.
    /// Unlike `scheduleSeek` this does NOT call `player.play()`, which avoids the
    /// play→pause round-trip that can stall the serial player queue for render-cycle
    /// intervals (10–90 ms each) when many events arrive in quick succession.
    func prepareSeek(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)? = nil) throws {
        let hadPending = pendingSeek != nil
        pendingSeek?.cancel()
        seekSerial += 1
        let serial = seekSerial
        try audioEngine.ensureRunning()
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [player] in
            guard !item.isCancelled else {
                return
            }
            let t0 = CACurrentMediaTime()
            player.stop()
            let stopMs = Int((CACurrentMediaTime() - t0) * 1000)
            Self.schedule(buffer, on: player, completion: completion)
        }
        pendingSeek = item
        audioEngine.playerQueue.async(execute: item)
    }

    // MARK: - Position / Sample-Rate Queries

    func playbackPosition() -> TimeInterval? {
        guard let nodeTime   = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    // MARK: - Configuration-Change Hook

    /// Called by `AudioEngineManager` when the audio hardware configuration changes.
    /// Resets playing state and reconnects nodes with the fresh player format.
    func handleEngineConfigurationChange() {
        isPlaying = false
        pendingSeek?.cancel()
        pendingSeek = nil
        audioEngine.connect(player: player, mixer: mixer)
    }

    // MARK: - Slicing & Scheduling

    /// Slices `fullBuffer` starting at `position` (seconds relative to cue-in) through
    /// cue-out, then either starts playback immediately (`startPlayback: true`) or
    /// parks the buffer at that position so `resume()` can begin without reloading.
    private func applySlice(from fullBuffer: AVAudioPCMBuffer,
                            track: Track,
                            position: TimeInterval,
                            generation gen: Int,
                            startPlayback: Bool = true) {
        let bufferSampleRate = fullBuffer.format.sampleRate
        let cueInFrame       = effectiveStartFrame(for: track, sampleRate: bufferSampleRate)
        let cueOutFrame      = effectiveEndFrame(for: track, sampleRate: bufferSampleRate)
        let absoluteFrame    = cueInFrame + AVAudioFramePosition(position * bufferSampleRate)

        seekTimeOffset = position

        let slice: AVAudioPCMBuffer?
        if let cueOut = cueOutFrame {
            let remaining = cueOut - absoluteFrame
            if remaining > 0 {
                slice = fullBuffer.sliced(fromFrame: absoluteFrame, length: AVAudioFrameCount(remaining))
            } else {
                slice = nil
            }
        } else {
            slice = fullBuffer.sliced(fromFrame: absoluteFrame)
        }

        guard let buffer = slice else { return }

        do {
            if startPlayback {
                try scheduleSeek(buffer) { [weak self] in
                    self?.handleTrackCompletion(generation: gen)
                }
                isPlaying = true
                startPositionTimer()
            } else {
                try prepareSeek(buffer) { [weak self] in
                    self?.handleTrackCompletion(generation: gen)
                }
                isPlaying = false
            }
            didStartTrack(track, generation: gen)
        } catch {
            print("\(type(of: self)): schedule error — \(error.localizedDescription)")
        }
    }

    /// Parks `fullBuffer` at position 0 on the player without starting playback,
    /// so a subsequent `resume()` begins at the beginning of the track.
    private func parkAtZero(fullBuffer: AVAudioPCMBuffer, track: Track) {
        let bufferSampleRate = fullBuffer.format.sampleRate
        seekTimeOffset = 0
        guard let slice = sliceForCuePoints(fullBuffer, track: track, sampleRate: bufferSampleRate) else {
            stopPlayer()
            return
        }
        do {
            try prepareSeek(slice)
        } catch {
            print("\(type(of: self)): prepare-seek error — \(error.localizedDescription)")
        }
    }

    /// Loads the full buffer for `track` on a background task, then invokes
    /// `onLoaded` on the main actor. No-ops if the generation has advanced or the
    /// task was cancelled before completion.
    private func loadBuffer(for track: Track,
                            generation gen: Int,
                            onLoaded: @escaping (AVAudioPCMBuffer) -> Void) {
        let url      = track.accessibleURL(libraryFolderURL: libraryFolderURL)
        let channel  = outputChannel
        guard let format = audioEngine.playerFormat else { return }

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let buffer = try AudioEngineManager.loadBuffer(
                    url: url,
                    outputChannel: channel,
                    playerFormat: format
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled, self.playbackGeneration == gen else { return }
                    onLoaded(buffer)
                }
            } catch {
                print("\(type(of: self)): load error — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Track Completion

    /// Internal completion dispatcher — called from the audio thread via the
    /// scheduleBuffer callback. Hops to main, checks the generation, and forwards
    /// to `onTrackCompletion(generation:)` (overridable).
    func handleTrackCompletion(generation gen: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.playbackGeneration == gen else { return }
            self.onTrackCompletion(generation: gen)
        }
    }

    // MARK: - Position Timer

    func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
    }

    func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func updatePosition() {
        guard isPlaying else { return }

        if let position = playbackPosition() {
            let computed = position + seekTimeOffset
            currentTime       = max(0, min(computed, duration))
        } else if !player.isPlaying {
            // Engine stopped unexpectedly (e.g. audio device removed). Reflect that.
            isPlaying = false
        }
    }

    // MARK: - Private Static

    private static func schedule(_ buffer: AVAudioPCMBuffer,
                                 on player: AVAudioPlayerNode,
                                 completion: (() -> Void)?) {
        if let completion {
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                completion()
            }
        } else {
            player.scheduleBuffer(buffer)
        }
    }
}
