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
    
    /// When true, ignores cue points and plays the full track.
    /// Useful for setting/adjusting cue points while auditioning.
    var bypassCuePoints: Bool = false

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

    /// Set by AppState when a library folder is opened.
    var libraryFolderURL: URL?

    init(audioEngine: AudioEngineManager) {
        self.audioEngine = audioEngine
    }

    deinit {
        positionTimer?.invalidate()
    }

    // MARK: - Loading

    /// Returns the effective duration of a track respecting cue points.
    private func effectiveDuration(for track: Track) -> TimeInterval {
        if bypassCuePoints {
            return track.duration
        }
        let cueIn = track.cuePointIn ?? 0
        let cueOut = track.cuePointOut ?? track.duration
        return max(0, cueOut - cueIn)
    }
    
    /// Returns the effective start frame accounting for cue-in.
    private func effectiveStartFrame(for track: Track, sampleRate: Double) -> AVAudioFramePosition {
        if bypassCuePoints {
            return 0
        }
        return track.cuePointIn.map { AVAudioFramePosition($0 * sampleRate) } ?? 0
    }
    
    /// Returns the effective end frame accounting for cue-out.
    private func effectiveEndFrame(for track: Track, sampleRate: Double) -> AVAudioFramePosition? {
        if bypassCuePoints {
            return nil
        }
        return track.cuePointOut.map { AVAudioFramePosition($0 * sampleRate) }
    }

    /// Loads a track into the preview player and begins playback.
    ///
    /// Always loads the FULL buffer so it's available for waveform display.
    /// Cue points are applied when scheduling playback, not during buffer load.
    func load(_ track: Track) {
        loadTask?.cancel()
        loadTask = nil
        stop()
        loadedBuffer = nil
        currentTrack = track
        duration = effectiveDuration(for: track)

        let url           = track.accessibleURL(libraryFolderURL: libraryFolderURL)
        let outputChannel = audioEngine.previewOutputChannel
        guard let format  = audioEngine.playerFormat else { return }

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Always load the FULL buffer for waveform display
                let buffer = try AudioEngineManager.loadBuffer(
                    url: url, 
                    outputChannel: outputChannel, 
                    playerFormat: format
                )
                
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.loadedBuffer = buffer
                    
                    // Apply cue points when scheduling playback
                    self.scheduleFromPosition(0)
                }
            } catch {
                print("PreviewPlaybackController: load error — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Transport Controls

    /// Resumes playback from the current position.
    func resume() {
        guard currentTrack != nil, !isPlaying else { return }
        audioEngine.resumePreview()
        isPlaying = true
        startPositionTimer()
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
        isPlaying = false
        currentTime = 0
        seekFrameOffset = 0
        stopPositionTimer()
        // Park the buffer at position 0 so resume() works after stop.
        // Falls back to a plain stop when the buffer hasn't loaded yet.
        if loadedBuffer != nil {
            scheduleFromPosition(0, autoPlay: false)
        } else {
            audioEngine.stopPreview()
        }
    }

    /// Toggles between resume and pause.
    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    /// Seeks to a specific position (in seconds) within the preview track.
    ///
    /// Position updates immediately. If the full buffer is cached the seek is a
    /// fast in-memory slice (memcpy, ~1–2 ms). Rapid drag events cancel any
    /// previous pending seek so only the final position triggers playback.
    func seek(to time: TimeInterval) {
        guard currentTrack != nil else { return }

        let clampedTime = max(0, min(time, duration))
        currentTime = clampedTime
        isPlaying = false
        stopPositionTimer()

        scheduleFromPosition(clampedTime)
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

    /// Slices the loaded buffer at `position` (seconds relative to cue-in), schedules
    /// it on the preview player, and optionally starts playback immediately.
    private func scheduleFromPosition(_ position: TimeInterval, autoPlay: Bool = true) {
        guard let track = currentTrack else { return }
        guard let buffer = loadedBuffer else { return }

        let sampleRate  = audioEngine.previewSampleRate()
        let cueInFrame  = effectiveStartFrame(for: track, sampleRate: sampleRate)
        let cueOutFrame = effectiveEndFrame(for: track, sampleRate: sampleRate)

        let absoluteFrame = cueInFrame + AVAudioFramePosition(position * sampleRate)

        guard let slice = buffer.sliced(fromFrame: absoluteFrame) else {
            print("PreviewPlaybackController: failed to slice buffer")
            return
        }

        let finalSlice: AVAudioPCMBuffer
        if let cueOut = cueOutFrame, !bypassCuePoints {
            let remainingFrames = cueOut - absoluteFrame
            if remainingFrames > 0, remainingFrames < slice.frameLength,
               let limited = slice.sliced(fromFrame: 0, length: AVAudioFrameCount(remainingFrames)) {
                finalSlice = limited
            } else {
                finalSlice = slice
            }
        } else {
            finalSlice = slice
        }

        seekFrameOffset = absoluteFrame

        do {
            if autoPlay {
                audioEngine.stopPreview()
                try audioEngine.scheduleSeekPreview(finalSlice)
                isPlaying = true
                startPositionTimer()
            } else {
                try audioEngine.prepareSeekPreview(finalSlice)
            }
        } catch {
            print("PreviewPlaybackController: schedule error — \(error.localizedDescription)")
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
