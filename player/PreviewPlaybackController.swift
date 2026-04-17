//
//  PreviewPlaybackController.swift
//  player
//

import AVFoundation
import Foundation
import Observation

/// Manages preview/cue playback on the right channel, allowing the DJ to
/// audition any track independently of the main playlist output.
@Observable
final class PreviewPlaybackController {

    // MARK: - Dependencies

    private let audioEngine: AudioEngineManager

    // MARK: - Observable State

    /// The track currently loaded in the preview player.
    private(set) var currentTrack: Track?

    /// Whether the preview player is currently playing.
    private(set) var isPlaying: Bool = false

    /// Current playback position within the preview track (seconds).
    private(set) var currentTime: TimeInterval = 0

    /// Total duration of the currently loaded preview track (seconds).
    private(set) var duration: TimeInterval = 0

    // MARK: - Internal State

    private var seekFrameOffset: AVAudioFramePosition = 0
    private var positionTimer: Timer?

    /// Full decoded buffer for the currently loaded track.
    /// Kept in memory so seeks can slice it without re-reading from disk.
    private var loadedBuffer: AVAudioPCMBuffer?

    /// Cancellable task for the initial background load (replaced on each load()).
    private var loadTask: Task<Void, Never>?

    // MARK: - Volume

    /// Preview output volume (0.0 ... 1.0). Delegates to AudioEngineManager.
    var volume: Float {
        get { audioEngine.previewVolume }
        set { audioEngine.previewVolume = newValue }
    }

    // MARK: - Init

    init(audioEngine: AudioEngineManager) {
        self.audioEngine = audioEngine
    }

    deinit {
        positionTimer?.invalidate()
    }

    // MARK: - Loading

    /// Loads a track into the preview player and begins playback.
    ///
    /// The full file is decoded once on a background task and cached as
    /// `loadedBuffer`. Subsequent seeks slice that buffer in memory —
    /// no further disk access or bookmark resolution required.
    func load(_ track: Track) {
        loadTask?.cancel()
        loadTask = nil
        stop()
        loadedBuffer = nil
        currentTrack = track
        duration = track.duration

        let url           = track.accessibleURL()
        let outputChannel = audioEngine.previewOutputChannel
        guard let format  = audioEngine.playerFormat else { return }

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let buffer = try AudioEngineManager.loadBuffer(
                    url: url, outputChannel: outputChannel, playerFormat: format)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.loadedBuffer    = buffer
                    self.seekFrameOffset = 0
                    try? self.audioEngine.scheduleSeekPreview(buffer)
                    self.isPlaying = true
                    self.startPositionTimer()
                }
            } catch {
                print("PreviewPlaybackController: load error — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Transport Controls

    /// Resumes or restarts playback from the current position.
    func play() {
        guard currentTrack != nil, !isPlaying else { return }
        scheduleFromCurrentPosition()
    }

    /// Pauses preview playback, retaining the current position.
    func pause() {
        guard isPlaying else { return }
        audioEngine.pausePreview()
        isPlaying = false
        stopPositionTimer()
    }

    /// Stops preview playback and resets position to zero.
    /// The decoded buffer is retained so the track can be replayed or seeked cheaply.
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        audioEngine.stopPreview()
        isPlaying = false
        currentTime = 0
        seekFrameOffset = 0
        stopPositionTimer()
    }

    /// Toggles between play and pause.
    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Seeks to a specific position (in seconds) within the preview track.
    ///
    /// Position updates immediately. If the full buffer is cached the seek is a
    /// fast in-memory slice (memcpy, ~1–2 ms). Rapid drag events cancel any
    /// previous pending seek so only the final position triggers playback.
    func seek(to time: TimeInterval) {
        guard currentTrack != nil else { return }

        let clampedTime = max(0, min(time, duration))
        let sampleRate  = audioEngine.previewSampleRate()
        let targetFrame = AVAudioFramePosition(clampedTime * sampleRate)

        currentTime     = clampedTime
        seekFrameOffset = targetFrame
        isPlaying       = false
        stopPositionTimer()

        scheduleFromCurrentPosition()
    }

    // MARK: - Unload

    /// Stops playback and clears the loaded track and its buffer.
    func unload() {
        stop()
        loadedBuffer = nil
        currentTrack = nil
        duration = 0
    }

    // MARK: - Private

    /// Schedules playback from `seekFrameOffset`, using the cached buffer if
    /// available (fast memcpy slice) or falling back to a background disk load.
    private func scheduleFromCurrentPosition() {
        let frame = seekFrameOffset

        if let buf = loadedBuffer, let slice = buf.sliced(fromFrame: frame) {
            // Fast path: slice the in-memory buffer — no disk access.
            audioEngine.stopPreview()
            do {
                try audioEngine.scheduleSeekPreview(slice)
                isPlaying = true
                startPositionTimer()
            } catch {
                print("PreviewPlaybackController: schedule error — \(error.localizedDescription)")
            }
            return
        }

        // Slow path: buffer not yet loaded (e.g. load() is still in progress).
        // This path should be rare; the load task stores loadedBuffer before
        // starting playback, so any seek arriving after that uses the fast path.
        guard let track = currentTrack else { return }
        let url           = track.accessibleURL()
        let outputChannel = audioEngine.previewOutputChannel
        guard let format  = audioEngine.playerFormat else { return }

        audioEngine.stopPreview()
        loadTask?.cancel()
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let buffer = try AudioEngineManager.loadBuffer(
                    url: url, fromFrame: frame, outputChannel: outputChannel, playerFormat: format)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    try? self.audioEngine.scheduleSeekPreview(buffer)
                    self.isPlaying = true
                    self.startPositionTimer()
                }
            } catch {
                print("PreviewPlaybackController: seek error — \(error.localizedDescription)")
            }
        }
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

        if let position = audioEngine.previewPlaybackPosition() {
            let offsetSeconds = Double(seekFrameOffset) / audioEngine.previewSampleRate()
            let computed = position + offsetSeconds
            currentTime = min(computed, duration)
        }
    }
}
