//
//  PreviewPlaybackController.swift
//  player
//

import AVFoundation
import Foundation
import Observation

/// Manages preview/cue playback on the right channel, allowing the DJ to
/// audition any track independently of the main playlist output.
///
/// Conceptually a single-track `PlaybackController` — no playlist, no prefetch,
/// no inter-track gap. Adds cue-point bypass (for setting/adjusting cue points
/// while auditioning) and `unload()` for clearing the loaded track.
@Observable
final class PreviewPlaybackController: PlaybackController {

    /// When true, ignores cue points and plays the full track.
    /// Useful for setting/adjusting cue points while auditioning.
    var bypassCuePoints: Bool = false {
        didSet {
            guard oldValue != bypassCuePoints, let track = currentTrack else { return }
            // Recompute duration so the UI seek bar reflects the new range.
            duration = effectiveDuration(for: track)
        }
    }

    override var shouldApplyCuePoints: Bool { !bypassCuePoints }

    // MARK: - Init

    init(audioEngine: AudioEngineManager) {
        super.init(audioEngine: audioEngine, outputChannel: .right)
    }

    // MARK: - Loading / Unloading

    /// Loads `track` into the preview player and begins playback from the start.
    func load(_ track: Track) {
        playTrack(track)
    }

    /// Stops playback and clears the loaded track and its buffer.
    func unload() {
        reset()
    }

}
