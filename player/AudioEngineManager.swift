import AVFoundation
import Observation

/// Manages the AVAudioEngine graph for a mono-split headphone preview system.
///
/// Two player nodes feed through individual mixer nodes that are panned hard-left
/// (main) and hard-right (preview). Both signals are mixed to mono before panning,
/// so a DJ using a stereo splitter cable hears the main output in one ear and the
/// cue/preview output in the other.
///
/// All main-output playback is buffer-based (files pre-loaded into `AVAudioPCMBuffer`)
/// to eliminate disk I/O on the audio render thread and enable seamless gapless
/// chaining between tracks.
@Observable
final class AudioEngineManager {

    // MARK: - Engine & Nodes

    private let engine = AVAudioEngine()
    private let mainPlayer = AVAudioPlayerNode()
    private let previewPlayer = AVAudioPlayerNode()
    private let mainMixer = AVAudioMixerNode()
    private let previewMixer = AVAudioMixerNode()

    // MARK: - Observable State

    private(set) var isMainPlaying: Bool = false
    private(set) var isPreviewPlaying: Bool = false

    // MARK: - Buffer Format

    /// The PCM format used for all main-player buffer scheduling.
    /// Derived from the engine's hardware output; all loaded buffers are converted to this.
    private(set) var playerFormat: AVAudioFormat!

    // MARK: - Volume

    var mainVolume: Float {
        get { mainMixer.outputVolume }
        set { mainMixer.outputVolume = newValue.clamped(to: 0...1) }
    }

    var previewVolume: Float {
        get { previewMixer.outputVolume }
        set { previewMixer.outputVolume = newValue.clamped(to: 0...1) }
    }

    // MARK: - Init / Teardown

    private var configChangeObserver: (any NSObjectProtocol)?

    init() {
        setupEngine()
    }

    deinit {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        engine.stop()
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        engine.attach(mainPlayer)
        engine.attach(previewPlayer)
        engine.attach(mainMixer)
        engine.attach(previewMixer)
        connectNodes()
        observeConfigurationChanges()
    }

    private func connectNodes() {
        // Derive the canonical stereo format from the hardware output.
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        playerFormat = format

        engine.connect(mainPlayer,    to: mainMixer,              format: format)
        engine.connect(previewPlayer, to: previewMixer,           format: format)
        engine.connect(mainMixer,     to: engine.mainMixerNode,   format: format)
        engine.connect(previewMixer,  to: engine.mainMixerNode,   format: format)

        mainMixer.pan    = -1.0   // hard left  → main output
        previewMixer.pan =  1.0   // hard right → cue/preview output
    }

    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    /// Handles audio hardware changes (e.g. headphones plugged/unplugged).
    /// Reconnects nodes with the new hardware format and restarts the engine.
    private func handleEngineConfigurationChange() {
        // Players lose their scheduled data when the engine stops; mark them stopped.
        isMainPlaying   = false
        isPreviewPlaying = false

        if engine.isRunning { engine.stop() }
        connectNodes()          // re-derive format + reconnect

        do {
            try engine.start()
        } catch {
            print("[AudioEngineManager] Restart after config change failed: \(error)")
        }
    }

    // MARK: - Engine Lifecycle

    func start() throws {
        guard !engine.isRunning else { return }
        try engine.start()
    }

    func stop() {
        mainPlayer.stop()
        previewPlayer.stop()
        engine.stop()
        isMainPlaying   = false
        isPreviewPlaying = false
    }

    // MARK: - Buffer Loading

    enum BufferError: Error {
        case allocationFailed
        case conversionFailed
        case invalidRange
    }

    /// Loads an entire audio file into a `AVAudioPCMBuffer` converted to the engine's
    /// player format. Safe to call from a background thread.
    func loadBuffer(url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        return try readAndConvert(file: file,
                                  startFrame: 0,
                                  frameCount: AVAudioFrameCount(file.length))
    }

    /// Loads the portion of an audio file from `startFrame` to the end.
    /// Used for seeks so the remaining segment is fully in memory.
    func loadBuffer(url: URL, fromFrame startFrame: AVAudioFramePosition) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard startFrame >= 0 && startFrame < file.length else { throw BufferError.invalidRange }
        let remaining = AVAudioFrameCount(file.length - startFrame)
        file.framePosition = startFrame
        return try readAndConvert(file: file, startFrame: startFrame, frameCount: remaining)
    }

    // MARK: - Buffer-Based Main Playback

    /// Stops any current main output and plays the supplied buffer.
    /// The completion handler fires when the buffer has been fully played back.
    func playMain(_ buffer: AVAudioPCMBuffer, completionHandler: @escaping () -> Void) throws {
        try ensureEngineRunning()
        mainPlayer.stop()
        mainPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            completionHandler()
        }
        mainPlayer.play()
        isMainPlaying = true
    }

    /// Appends a buffer to the main player's queue WITHOUT stopping.
    /// The buffer plays seamlessly immediately after all currently-queued content.
    /// Call this while a track is already playing to achieve zero-gap track transitions.
    func chainMain(_ buffer: AVAudioPCMBuffer, completionHandler: @escaping () -> Void) {
        mainPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            completionHandler()
        }
        // Do NOT call stop() or play() — the player is already running.
    }

    // MARK: - Main Player Controls

    func stopMain() {
        mainPlayer.stop()
        isMainPlaying = false
    }

    func pauseMain() {
        mainPlayer.pause()
        isMainPlaying = false
    }

    func resumeMain() {
        mainPlayer.play()
        isMainPlaying = true
    }

    /// Seeks to `startFrame` within the file and plays the remaining segment.
    /// The remaining segment is fully loaded into a buffer to keep subsequent
    /// chaining buffer-based and avoid mixing file/buffer scheduling modes.
    func seekMain(url: URL, toFrame startFrame: AVAudioFramePosition,
                  completionHandler: @escaping () -> Void) throws {
        let buffer = try loadBuffer(url: url, fromFrame: startFrame)
        try ensureEngineRunning()
        mainPlayer.stop()
        mainPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            completionHandler()
        }
        mainPlayer.play()
        isMainPlaying = true
    }

    func mainPlaybackPosition() -> TimeInterval? {
        guard let nodeTime   = mainPlayer.lastRenderTime,
              let playerTime = mainPlayer.playerTime(forNodeTime: nodeTime) else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    func mainSampleRate() -> Double {
        if let nodeTime   = mainPlayer.lastRenderTime,
           let playerTime = mainPlayer.playerTime(forNodeTime: nodeTime) {
            return playerTime.sampleRate
        }
        return engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
    }

    // MARK: - Preview Player (file-based, no chaining needed)

    func playOnPreview(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        try ensureEngineRunning()
        previewPlayer.stop()
        previewPlayer.scheduleFile(file, at: nil)
        previewPlayer.play()
        isPreviewPlaying = true
    }

    func playOnPreview(url: URL, completionHandler: @escaping () -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        try ensureEngineRunning()
        previewPlayer.stop()
        previewPlayer.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
            completionHandler()
        }
        previewPlayer.play()
        isPreviewPlaying = true
    }

    func seekPreview(url: URL, toFrame startFrame: AVAudioFramePosition,
                     completionHandler: (() -> Void)? = nil) throws {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = file.length
        guard startFrame >= 0 && startFrame < totalFrames else { return }

        try ensureEngineRunning()
        let frameCount = AVAudioFrameCount(totalFrames - startFrame)
        previewPlayer.stop()
        if let completion = completionHandler {
            previewPlayer.scheduleSegment(file, startingFrame: startFrame,
                                          frameCount: frameCount, at: nil,
                                          completionCallbackType: .dataPlayedBack) { _ in completion() }
        } else {
            previewPlayer.scheduleSegment(file, startingFrame: startFrame,
                                          frameCount: frameCount, at: nil)
        }
        previewPlayer.play()
        isPreviewPlaying = true
    }

    func stopPreview() {
        previewPlayer.stop()
        isPreviewPlaying = false
    }

    func pausePreview() {
        previewPlayer.pause()
        isPreviewPlaying = false
    }

    func resumePreview() {
        previewPlayer.play()
        isPreviewPlaying = true
    }

    func previewPlaybackPosition() -> TimeInterval? {
        guard let nodeTime   = previewPlayer.lastRenderTime,
              let playerTime = previewPlayer.playerTime(forNodeTime: nodeTime) else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    func previewSampleRate() -> Double {
        if let nodeTime   = previewPlayer.lastRenderTime,
           let playerTime = previewPlayer.playerTime(forNodeTime: nodeTime) {
            return playerTime.sampleRate
        }
        return engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
    }

    var previewCurrentTime: TimeInterval { previewPlaybackPosition() ?? 0 }
    var previewDuration: TimeInterval { 0 }

    // MARK: - Private Helpers

    private func ensureEngineRunning() throws {
        if !engine.isRunning { try engine.start() }
    }

    /// Reads `frameCount` frames from `file` (starting at its current `framePosition`)
    /// into a buffer and converts to `playerFormat` if needed.
    private func readAndConvert(file: AVAudioFile,
                                startFrame: AVAudioFramePosition,
                                frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let fileFormat = file.processingFormat

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat,
                                                   frameCapacity: frameCount) else {
            throw BufferError.allocationFailed
        }
        try file.read(into: sourceBuffer)

        // Fast path: no conversion needed.
        let target = playerFormat!
        if fileFormat.sampleRate   == target.sampleRate &&
           fileFormat.channelCount == target.channelCount {
            return sourceBuffer
        }

        // Convert sample rate / channel count to match the engine's player format.
        guard let converter = AVAudioConverter(from: fileFormat, to: target) else {
            throw BufferError.conversionFailed
        }
        let ratio          = target.sampleRate / fileFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target,
                                                   frameCapacity: outputCapacity) else {
            throw BufferError.allocationFailed
        }

        var inputConsumed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputConsumed { outStatus.pointee = .endOfStream; return nil }
            inputConsumed        = true
            outStatus.pointee    = .haveData
            return sourceBuffer
        }
        if let err = conversionError { throw err }
        return outputBuffer
    }
}

// MARK: - Clamping

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
