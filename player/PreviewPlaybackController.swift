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
    func load(_ track: Track) throws {
        stop()
        currentTrack = track
        duration = track.duration
        try audioEngine.playOnPreview(url: track.fileURL)
        isPlaying = true
        seekFrameOffset = 0
        startPositionTimer()
    }

    // MARK: - Transport Controls

    /// Resumes playback if paused, or restarts the current track if stopped.
    func play() throws {
        guard let track = currentTrack else { return }

        if !isPlaying {
            try audioEngine.playOnPreview(url: track.fileURL)
            isPlaying = true
            startPositionTimer()
        }
    }

    /// Pauses preview playback, retaining the current position.
    func pause() {
        guard isPlaying else { return }
        audioEngine.pausePreview()
        isPlaying = false
        stopPositionTimer()
    }

    /// Stops preview playback and resets position.
    func stop() {
        audioEngine.stopPreview()
        isPlaying = false
        currentTime = 0
        seekFrameOffset = 0
        stopPositionTimer()
    }

    /// Toggles between play and pause.
    func togglePlayPause() throws {
        if isPlaying {
            pause()
        } else {
            try play()
        }
    }

    /// Seeks to a specific position (in seconds) within the preview track.
    func seek(to time: TimeInterval) {
        guard let track = currentTrack else { return }

        let clampedTime = max(0, min(time, duration))
        let sampleRate = audioEngine.previewSampleRate()
        let targetFrame = AVAudioFramePosition(clampedTime * sampleRate)

        seekFrameOffset = targetFrame

        do {
            try audioEngine.seekPreview(url: track.fileURL, toFrame: targetFrame)
            isPlaying = true
            currentTime = clampedTime
            startPositionTimer()
        } catch {
            print("PreviewPlaybackController: seek error — \(error.localizedDescription)")
        }
    }

    // MARK: - Unload

    /// Stops playback and clears the loaded track.
    func unload() {
        stop()
        currentTrack = nil
        duration = 0
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
