//
//  EngineConfigChangePlaybackTests.swift
//  playerTests
//
//  Reproduces a bug where a *paused* MainPlaybackController auto-advances to the
//  next track in its queue when the audio engine configuration changes (e.g.
//  headphones plugged/unplugged). The expected behaviour is that the controller
//  remains paused on the same track at the same position.
//
//  Suspected cause: handleEngineConfigurationChange() calls stopPlayer(), which
//  dispatches player.stop() on the player queue. stop() flushes any scheduled
//  buffer and triggers its .dataPlayedBack completion handler. Because
//  playbackGeneration is *not* bumped inside handleEngineConfigurationChange(),
//  the stale completion passes its generation guard, fires
//  onTrackCompletion(generation:), and on MainPlaybackController runs
//  autoAdvance() — which calls playTrack(at: next) with the default
//  startPlayback: true and starts the next track in the queue.
//

import XCTest
@testable import player
@preconcurrency import AVFoundation

@MainActor
final class EngineConfigChangePlaybackTests: XCTestCase {

    // MARK: - Fixture

    private var tempFiles: [URL] = []

    override func tearDown() async throws {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles = []
    }

    /// Writes a short sine-wave .caf file to the temp directory and tracks it
    /// for cleanup. Real on-disk file because PlaybackController loads buffers
    /// via AVAudioFile and the test must exercise the real loading path.
    private func makeTestFile(durationSeconds: Double) throws -> URL {
        let sampleRate: Double = 44_100
        let frames = AVAudioFrameCount(durationSeconds * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sin(Float(i) * 0.05) * 0.5
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buf)
        tempFiles.append(url)
        return url
    }

    private func makeTrack(url: URL, duration: TimeInterval) -> Track {
        Track(
            relativePath: url.lastPathComponent,
            fileURL: url,
            title: url.deletingPathExtension().lastPathComponent,
            duration: duration
        )
    }

    /// Polls `condition` until true or `timeout` elapses. The `Task.sleep`
    /// hand-off lets dispatched main-queue work (e.g. completion callbacks
    /// re-entering main via `DispatchQueue.main.async`) land between checks.
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)   // 10 ms
        }
    }

    /// Yields for `duration` seconds — used after triggering the config change
    /// so cross-thread completion callbacks that re-enter the main queue have
    /// time to run before assertions.
    private func runMainLoop(for duration: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }

    /// Drains a serial dispatch queue without blocking the calling thread.
    /// `queue.sync {}` from a high-QoS thread (main is user-interactive) onto a
    /// lower-QoS queue triggers Thread Performance Checker priority-inversion
    /// warnings. Use this instead — it dispatches a marker block and awaits a
    /// continuation, so the calling thread yields rather than blocks.
    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - Tests

    /// A paused MainPlaybackController must not auto-advance when the audio
    /// engine configuration changes. The buggy path: stopPlayer() inside
    /// handleEngineConfigurationChange() fires the scheduled buffer's
    /// completion callback, which is not generation-guarded out and runs
    /// autoAdvance(), starting the next track.
    func test_pausedMainController_doesNotAutoAdvance_onConfigChange() async throws {
        let manager = AudioEngineManager()
        let controller = MainPlaybackController(audioEngine: manager)

        let url1 = try makeTestFile(durationSeconds: 2)
        let url2 = try makeTestFile(durationSeconds: 2)
        let track1 = makeTrack(url: url1, duration: 2)
        let track2 = makeTrack(url: url2, duration: 2)

        controller.loadTracks([track1, track2])

        // Wait for track 0 buffer to be preloaded by preloadFirstTrack().
        await waitFor(timeout: 3) { controller.currentFullBuffer != nil }
        XCTAssertNotNil(controller.currentFullBuffer, "Track 0 buffer should be preloaded")

        // Begin playback. play() takes the slow load path here (preloadedBuffer
        // is for the *next* track, not track 0), so wait for the buffer and
        // for isPlaying to flip true.
        controller.play()
        await waitFor(timeout: 3) { controller.isPlaying && controller.currentFullBuffer != nil }
        XCTAssertTrue(controller.isPlaying, "Controller should be playing track 0")

        // Drain the player queue so the schedule-buffer + play() work item
        // dispatched by scheduleSeek() has actually run on the player node.
        await drain(manager.playerQueue)

        // Pause.
        controller.pause()
        XCTAssertFalse(controller.isPlaying, "Controller should be paused")
        await drain(manager.playerQueue)     // let player.pause() land

        let pausedTrackID = controller.currentTrack?.id
        let pausedIndex   = controller.currentTrackIndex
        XCTAssertEqual(pausedIndex, 0, "Should still be on track 0 before config change")

        // Trigger the controller-side half of a config change. We don't
        // restart the real engine — the bug is triggered purely by the
        // controller's stopPlayer() call firing the scheduled buffer's
        // completion handler while playbackGeneration is unchanged.
        controller.handleEngineConfigurationChange()
        controller.resumeAfterEngineRestart()

        // Drain the player queue so the dispatched player.stop() runs (and
        // fires the .dataPlayedBack completion for the scheduled buffer).
        await drain(manager.playerQueue)

        // The completion handler hops to the main queue via
        // handleTrackCompletion → DispatchQueue.main.async, so pump the main
        // loop long enough for that hop to land.
        await runMainLoop(for: 0.5)

        XCTAssertFalse(
            controller.isPlaying,
            "Paused controller must remain paused after a config change"
        )
        XCTAssertEqual(
            controller.currentTrackIndex, pausedIndex,
            "Paused controller must not advance to the next track"
        )
        XCTAssertEqual(
            controller.currentTrack?.id, pausedTrackID,
            "Paused controller must not change current track"
        )
    }

    /// A *playing* MainPlaybackController must not advance to the next track
    /// when the audio engine's sample rate changes (e.g. headphones in/out
    /// switching the hardware output rate). The expected behaviour is to stay
    /// on the same track and resume playback at the same position, with the
    /// in-memory buffer reloaded at the new rate.
    ///
    /// Simulates the full AudioEngineManager.handleEngineConfigurationChange
    /// flow: stop the engine, change `playerFormat` to the new rate, run each
    /// controller's `handleEngineConfigurationChange()`, restart the engine,
    /// then call `resumeAfterEngineRestart()`. Mutates `manager.playerFormat`
    /// directly because the real flow reads the new rate from hardware, which
    /// can't be deterministically driven from a unit test.
    func test_playingMainController_doesNotAdvanceTrack_onConfigChangeWithDifferentSampleRate() async throws {
        let manager = AudioEngineManager()
        let controller = MainPlaybackController(audioEngine: manager)

        let url1 = try makeTestFile(durationSeconds: 2)
        let url2 = try makeTestFile(durationSeconds: 2)
        let track1 = makeTrack(url: url1, duration: 2)
        let track2 = makeTrack(url: url2, duration: 2)

        controller.loadTracks([track1, track2])
        await waitFor(timeout: 3) { controller.currentFullBuffer != nil }

        controller.play()
        await waitFor(timeout: 3) { controller.isPlaying && controller.currentFullBuffer != nil }
        XCTAssertTrue(controller.isPlaying, "Controller should be playing track 0")
        await drain(manager.playerQueue)

        // Give prefetch a chance to populate the next-track buffer at the
        // pre-change rate — that mirrors the real-world state at the moment
        // the hardware switches.
        await runMainLoop(for: 0.4)

        let originalRate = manager.playerFormat.sampleRate
        let originalBufferRate = controller.currentFullBuffer?.format.sampleRate
        XCTAssertEqual(originalBufferRate, originalRate,
                       "Test precondition: pre-change buffer must match pre-change playerFormat")

        let beforeIndex = controller.currentTrackIndex
        let beforeTrackID = controller.currentTrack?.id

        // Faithfully mirror AudioEngineManager.handleEngineConfigurationChange.
        let newRate: Double = (originalRate >= 44_100) ? 22_050 : 48_000
        XCTAssertNotEqual(newRate, originalRate, "Test precondition")

        if manager.engine.isRunning { manager.engine.stop() }
        manager.playerFormat = AVAudioFormat(standardFormatWithSampleRate: newRate, channels: 2)
        controller.handleEngineConfigurationChange()
        try? manager.engine.start()
        controller.resumeAfterEngineRestart()

        // Drain the player queue so the dispatched player.stop() runs (and
        // fires any .dataPlayedBack completion for the pre-change buffer).
        await drain(manager.playerQueue)

        // resumeAfterEngineRestart kicks off an async buffer reload at the new
        // sample rate. Wait for it to land and for playback to resume.
        await waitFor(timeout: 3) {
            controller.isPlaying
                && controller.currentFullBuffer?.format.sampleRate == newRate
        }

        XCTAssertEqual(
            controller.currentTrackIndex, beforeIndex,
            "Controller must not advance to the next track on sample-rate change"
        )
        XCTAssertEqual(
            controller.currentTrack?.id, beforeTrackID,
            "Controller must not change current track on sample-rate change"
        )
        XCTAssertTrue(
            controller.isPlaying,
            "Controller must resume playing after a sample-rate config change"
        )
        XCTAssertEqual(
            controller.currentFullBuffer?.format.sampleRate, newRate,
            "Buffer must be reloaded at the new sample rate"
        )
    }

    /// Reproduces the *real-world* race: AVAudioEngine internally stops itself
    /// before posting `AVAudioEngineConfigurationChange`. The `engine.stop()`
    /// flushes the scheduled buffer and fires its `.dataPlayedBack` completion
    /// from the audio thread; that completion's main-queue dispatch is queued
    /// BEFORE our notification handler. So when main runs the stale completion,
    /// `playbackGeneration` hasn't been bumped yet — the gen guard alone won't
    /// catch this. The fix is to also gate on `engine.isRunning`: a natural
    /// buffer-end fires while the engine is running; a forced engine stop fires
    /// after it has gone idle.
    func test_playingMainController_doesNotAutoAdvance_whenEngineStopsBeforeConfigChangeHandler() async throws {
        let manager = AudioEngineManager()
        let controller = MainPlaybackController(audioEngine: manager)

        let url1 = try makeTestFile(durationSeconds: 2)
        let url2 = try makeTestFile(durationSeconds: 2)
        let track1 = makeTrack(url: url1, duration: 2)
        let track2 = makeTrack(url: url2, duration: 2)

        controller.loadTracks([track1, track2])
        await waitFor(timeout: 3) { controller.currentFullBuffer != nil }

        controller.play()
        await waitFor(timeout: 3) { controller.isPlaying && controller.currentFullBuffer != nil }
        XCTAssertTrue(controller.isPlaying, "Controller should be playing track 0")
        await drain(manager.playerQueue)
        await runMainLoop(for: 0.3)             // give prefetch a chance to land

        let beforeIndex = controller.currentTrackIndex
        let beforeTrackID = controller.currentTrack?.id

        // AVAudioEngine internally stops itself before posting the config-change
        // notification. Stop the engine here to simulate that — the scheduled
        // buffer's .dataPlayedBack callback fires from the audio thread and
        // dispatches its main-hop. We then drain main *before* invoking our
        // controller-side handler, mimicking the real ordering where the stale
        // completion's main-hop runs first.
        manager.engine.stop()
        await drain(manager.playerQueue)
        await runMainLoop(for: 0.3)

        // Now run the controller-side config-change handler, then restart the
        // engine and resume. (No sample-rate change here — we're isolating the
        // ordering bug, not the format-mismatch path.)
        controller.handleEngineConfigurationChange()
        try? manager.engine.start()
        controller.resumeAfterEngineRestart()

        await drain(manager.playerQueue)
        await runMainLoop(for: 0.5)

        XCTAssertEqual(
            controller.currentTrackIndex, beforeIndex,
            "Controller must not advance when engine stops before the config-change handler runs"
        )
        XCTAssertEqual(
            controller.currentTrack?.id, beforeTrackID,
            "Controller must not change current track across this race"
        )
    }

    /// Reproduces a paused-playback bug: when the user pauses, then a config
    /// change occurs (engine internally stops, dropping the scheduled buffer),
    /// then the user resumes — `player.play()` had nothing to play, so the UI
    /// would show "playing" but no audio came out. The fix re-schedules the
    /// loaded buffer in `resumeAfterEngineRestart` even when paused, so that
    /// the player has a buffer ready when `resume()` runs.
    ///
    /// Position advancement is *not* a reliable signal — the engine renders
    /// silence through an idle player and `lastRenderTime` keeps ticking. So
    /// the test installs a tap on the controller's mixer node and verifies
    /// that non-silent samples actually flow after the resume.
    func test_pausedPreviewController_audibleAfterResumeFollowingConfigChange() async throws {
        let manager = AudioEngineManager()
        let controller = PreviewPlaybackController(audioEngine: manager)

        let url = try makeTestFile(durationSeconds: 4)
        let track = makeTrack(url: url, duration: 4)

        controller.load(track)
        await waitFor(timeout: 3) { controller.isPlaying && controller.currentFullBuffer != nil }
        await drain(manager.playerQueue)
        await runMainLoop(for: 0.2)

        controller.pause()
        XCTAssertFalse(controller.isPlaying)
        await drain(manager.playerQueue)

        let pausedTime = controller.currentTime

        // Replicate the real engine ordering: engine internally stops and
        // flushes the scheduled buffer BEFORE the notification handler runs.
        manager.engine.stop()
        await drain(manager.playerQueue)
        await runMainLoop(for: 0.3)

        controller.handleEngineConfigurationChange()
        try? manager.engine.start()
        controller.resumeAfterEngineRestart()

        await drain(manager.playerQueue)
        await runMainLoop(for: 0.3)

        // Sanity: still paused on the same track at the same position.
        XCTAssertFalse(controller.isPlaying, "Should remain paused after config change")
        XCTAssertEqual(controller.currentTrack?.id, track.id)
        XCTAssertEqual(controller.currentTime, pausedTime, accuracy: 0.2)

        // Install a tap on the controller's mixer to monitor actual audio
        // output. The tap callback fires with each render slice; we record
        // whether any slice contains a non-silent sample.
        let nonSilentObserved = NonSilenceMonitor()
        let tapBus: AVAudioNodeBus = 0
        let tapFormat = controller.mixer.outputFormat(forBus: tapBus)
        controller.mixer.installTap(onBus: tapBus, bufferSize: 1024, format: tapFormat) { buffer, _ in
            let frames = Int(buffer.frameLength)
            guard frames > 0, let chData = buffer.floatChannelData else { return }
            let chans = Int(buffer.format.channelCount)
            for ch in 0..<chans {
                let p = chData[ch]
                for i in 0..<frames where abs(p[i]) > 0.01 {
                    nonSilentObserved.set()
                    return
                }
            }
        }
        defer { controller.mixer.removeTap(onBus: tapBus) }

        controller.resume()
        XCTAssertTrue(controller.isPlaying, "Controller-side flag flips on resume")
        await drain(manager.playerQueue)
        // Wait for several render slices to flow through the tap.
        await waitFor(timeout: 2.0) { nonSilentObserved.value }

        XCTAssertTrue(
            nonSilentObserved.value,
            "Audio output must be non-silent after resume — buffer must have been re-scheduled across config change"
        )
    }

    /// Thread-safe boolean used by the audio tap callback (audio thread) and
    /// the test code (main).
    private final class NonSilenceMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
        func set() { lock.lock(); _value = true; lock.unlock() }
    }

    /// Same shape, but on the single-track (preview) controller: no playlist,
    /// so the bug manifests as plain unwanted resume rather than queue advance.
    /// Even though the default onTrackCompletion just stops, the symptom we
    /// care about here is that isPlaying may flip back on or position may jump.
    func test_pausedPreviewController_remainsPausedAtSamePosition_onConfigChange() async throws {
        let manager = AudioEngineManager()
        let controller = PreviewPlaybackController(audioEngine: manager)

        let url = try makeTestFile(durationSeconds: 2)
        let track = makeTrack(url: url, duration: 2)

        controller.load(track)

        await waitFor(timeout: 3) { controller.isPlaying && controller.currentFullBuffer != nil }
        XCTAssertTrue(controller.isPlaying, "Preview should be playing")
        await drain(manager.playerQueue)

        controller.pause()
        XCTAssertFalse(controller.isPlaying)
        await drain(manager.playerQueue)

        let pausedTrackID = controller.currentTrack?.id
        let pausedTime    = controller.currentTime

        controller.handleEngineConfigurationChange()
        controller.resumeAfterEngineRestart()

        await drain(manager.playerQueue)
        await runMainLoop(for: 0.5)

        XCTAssertFalse(
            controller.isPlaying,
            "Paused preview must remain paused after config change"
        )
        XCTAssertEqual(
            controller.currentTrack?.id, pausedTrackID,
            "Preview track must not change after config change"
        )
        // Position should not have advanced — the controller was paused.
        // Use a small tolerance for any in-flight position-timer tick.
        XCTAssertEqual(
            controller.currentTime, pausedTime, accuracy: 0.1,
            "Paused preview position must not change after config change"
        )
    }
}
