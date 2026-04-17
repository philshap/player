@preconcurrency import AVFoundation
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

    /// Pending seek work items — cancelled when a newer seek arrives so stale
    /// seeks are skipped rather than executing in order on playerQueue.
    /// Must only be accessed from the main thread.
    private var pendingSeekMain:    DispatchWorkItem?
    private var pendingSeekPreview: DispatchWorkItem?

    /// Serial queue for all AVAudioPlayerNode operations.
    ///
    /// AVAudioPlayerNode.stop/play/scheduleBuffer synchronise internally with
    /// AVFoundation infrastructure that runs at Default QoS. Calling them from
    /// the main actor (User-Interactive QoS) causes priority inversion warnings.
    /// Dispatching to this queue keeps the caller non-blocking and ensures the
    /// operations execute at a priority that matches AVFoundation's own threads.
    private let playerQueue = DispatchQueue(label: "com.player.audioengine", qos: .default)

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

    /// Controls which channel(s) main audio is routed to.
    /// `.left` = mono-split cable mode (preview in left ear only).
    /// `.both`  = stereo monitoring mode (preview in both ears).
    var mainOutputChannel: OutputChannel = .left

    /// Controls which channel(s) preview audio is routed to.
    /// `.right` = mono-split cable mode (preview in right ear only).
    /// `.both`  = stereo monitoring mode (preview in both ears).
    var previewOutputChannel: OutputChannel = .right

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
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)

        // Always use explicit 2-channel stereo regardless of what the engine reports.
        // Channel isolation is enforced by the buffer content (L=signal/R=0 for main,
        // L=0/R=signal for preview) rather than by AVAudioMixerNode.pan, which is
        // unreliable across hardware configurations and macOS versions.
        guard let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: max(outputFormat.sampleRate, 44_100),
            channels: 2
        ) else { return }

        playerFormat = stereoFormat

        // All connections are stereo. The mixers are kept for per-player volume control.
        // No pan is applied — channel routing is entirely determined by the buffers.
        engine.connect(mainPlayer,    to: mainMixer,            format: stereoFormat)
        engine.connect(previewPlayer, to: previewMixer,         format: stereoFormat)
        engine.connect(mainMixer,     to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(previewMixer,  to: engine.mainMixerNode, format: stereoFormat)
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

    /// Which output channel(s) a buffer should carry signal in.
    /// `.left` and `.right` zero the opposite channel for mono-split routing.
    /// `.both` places the signal in both channels (stereo headphone monitoring).
    enum OutputChannel { case left, right, both }

    // MARK: Instance convenience (main-actor, for synchronous call sites)

    /// Loads a whole file as a stereo buffer with audio in the left channel (main output).
    func loadBufferForMain(url: URL) throws -> AVAudioPCMBuffer {
        try loadBufferForMain(url: url, fromFrame: 0)
    }

    /// Loads from `startFrame` to end, audio in the left channel (main seek).
    func loadBufferForMain(url: URL, fromFrame startFrame: AVAudioFramePosition) throws -> AVAudioPCMBuffer {
        try Self.loadBuffer(url: url, fromFrame: startFrame, outputChannel: mainOutputChannel, playerFormat: playerFormat)
    }

    /// Loads a whole file as a stereo buffer for preview output.
    /// Channel routing is determined by `previewOutputChannel`.
    func loadBufferForPreview(url: URL) throws -> AVAudioPCMBuffer {
        try Self.loadBuffer(url: url, outputChannel: previewOutputChannel, playerFormat: playerFormat)
    }

    // MARK: Static background-safe loaders (no actor state — pass playerFormat from main actor)

    /// Background-safe full-file loader. Capture `audioEngine.playerFormat` before entering a Task.
    nonisolated static func loadBuffer(url: URL, outputChannel: OutputChannel,
                                       playerFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        return try loadBuffer(url: url, fromFrame: 0, outputChannel: outputChannel, playerFormat: playerFormat)
    }

    /// Background-safe seek loader.
    nonisolated static func loadBuffer(url: URL, fromFrame startFrame: AVAudioFramePosition,
                                       outputChannel: OutputChannel,
                                       playerFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard startFrame >= 0 && startFrame < file.length else { throw BufferError.invalidRange }
        file.framePosition = startFrame
        let remaining = AVAudioFrameCount(file.length - startFrame)
        return try buildChannelBuffer(file: file,
                                      frameCount: remaining,
                                      outputChannel: outputChannel,
                                      playerFormat: playerFormat)
    }

    // MARK: - Buffer-Based Main Playback

    /// Stops any current main output and plays the supplied buffer.
    /// The completion handler fires when the buffer has been fully played back.
    func playMain(_ buffer: AVAudioPCMBuffer, completionHandler: @escaping () -> Void) throws {
        pendingSeekMain?.cancel()
        pendingSeekMain = nil
        try ensureEngineRunning()
        isMainPlaying = true
        playerQueue.async { [mainPlayer] in
            mainPlayer.stop()
            mainPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                completionHandler()
            }
            mainPlayer.play()
        }
    }

    /// Appends a buffer to the main player's queue WITHOUT stopping.
    /// The buffer plays seamlessly immediately after all currently-queued content.
    /// Call this while a track is already playing to achieve zero-gap track transitions.
    func chainMain(_ buffer: AVAudioPCMBuffer, completionHandler: @escaping () -> Void) {
        playerQueue.async { [mainPlayer] in
            mainPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                completionHandler()
            }
        }
        // Do NOT call stop() or play() — the player is already running.
    }

    // MARK: - Main Player Controls

    func stopMain() {
        pendingSeekMain?.cancel()
        pendingSeekMain = nil
        isMainPlaying = false
        playerQueue.async { [mainPlayer] in mainPlayer.stop() }
    }

    func pauseMain() {
        isMainPlaying = false
        playerQueue.async { [mainPlayer] in mainPlayer.pause() }
    }

    func resumeMain() {
        isMainPlaying = true
        playerQueue.async { [mainPlayer] in mainPlayer.play() }
    }

    /// Seeks to `startFrame` within the file and plays the remaining segment.
    /// The remaining segment is fully loaded into a buffer to keep subsequent
    /// chaining buffer-based and avoid mixing file/buffer scheduling modes.
    func seekMain(url: URL, toFrame startFrame: AVAudioFramePosition,
                  completionHandler: @escaping () -> Void) throws {
        let buffer = try loadBufferForMain(url: url, fromFrame: startFrame)
        try ensureEngineRunning()
        isMainPlaying = true
        playerQueue.async { [mainPlayer] in
            mainPlayer.stop()
            mainPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                completionHandler()
            }
            mainPlayer.play()
        }
    }

    /// Schedules a pre-sliced buffer for seek playback on the main player.
    ///
    /// Cancels any pending seek work item before dispatching the new one, so rapid
    /// seeks (e.g. slider dragging) skip stale positions instead of queuing them up.
    /// The buffer must already be sliced to start at the desired frame — no disk I/O.
    func scheduleSeekMain(_ buffer: AVAudioPCMBuffer,
                          completionHandler: @escaping () -> Void) throws {
        pendingSeekMain?.cancel()
        try ensureEngineRunning()
        isMainPlaying = true
        let item = DispatchWorkItem { [mainPlayer] in
            mainPlayer.stop()
            mainPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                completionHandler()
            }
            mainPlayer.play()
        }
        pendingSeekMain = item
        playerQueue.async(execute: item)
    }

    /// Schedules a pre-sliced buffer for seek playback on the preview player.
    /// Cancels any pending seek work item before dispatching.
    func scheduleSeekPreview(_ buffer: AVAudioPCMBuffer) throws {
        pendingSeekPreview?.cancel()
        try ensureEngineRunning()
        isPreviewPlaying = true
        let item = DispatchWorkItem { [previewPlayer] in
            previewPlayer.stop()
            previewPlayer.scheduleBuffer(buffer)
            previewPlayer.play()
        }
        pendingSeekPreview = item
        playerQueue.async(execute: item)
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

    // MARK: - Preview Player
    // Uses the same buffer-based approach as the main player so that stereo audio
    // files are downmixed to mono before reaching the mixer.  scheduleFile /
    // scheduleSegment cannot be used here because AVAudioPlayerNode throws a
    // runtime exception when a stereo file is scheduled on a node whose
    // downstream connection carries a mono format.

    func playOnPreview(url: URL) throws {
        let buffer = try loadBufferForPreview(url: url)
        try ensureEngineRunning()
        isPreviewPlaying = true
        playerQueue.async { [previewPlayer] in
            previewPlayer.stop()
            previewPlayer.scheduleBuffer(buffer)
            previewPlayer.play()
        }
    }

    func playOnPreview(url: URL, completionHandler: @escaping () -> Void) throws {
        let buffer = try loadBufferForPreview(url: url)
        try ensureEngineRunning()
        isPreviewPlaying = true
        playerQueue.async { [previewPlayer] in
            previewPlayer.stop()
            previewPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                completionHandler()
            }
            previewPlayer.play()
        }
    }

    func seekPreview(url: URL, toFrame startFrame: AVAudioFramePosition,
                     completionHandler: (() -> Void)? = nil) throws {
        let buffer = try Self.loadBuffer(url: url, fromFrame: startFrame,
                                         outputChannel: previewOutputChannel, playerFormat: playerFormat)
        try ensureEngineRunning()
        isPreviewPlaying = true
        playerQueue.async { [previewPlayer] in
            previewPlayer.stop()
            if let completion = completionHandler {
                previewPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    completion()
                }
            } else {
                previewPlayer.scheduleBuffer(buffer)
            }
            previewPlayer.play()
        }
    }

    /// Stops current preview output and plays a pre-loaded buffer.
    /// Mirrors `playMain(_:completionHandler:)` — callers are responsible for loading
    /// the buffer on a background thread before calling this.
    func playPreview(_ buffer: AVAudioPCMBuffer, completionHandler: (() -> Void)? = nil) throws {
        try ensureEngineRunning()
        isPreviewPlaying = true
        playerQueue.async { [previewPlayer] in
            previewPlayer.stop()
            if let completion = completionHandler {
                previewPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    completion()
                }
            } else {
                previewPlayer.scheduleBuffer(buffer)
            }
            previewPlayer.play()
        }
    }

    func stopPreview() {
        pendingSeekPreview?.cancel()
        pendingSeekPreview = nil
        isPreviewPlaying = false
        playerQueue.async { [previewPlayer] in previewPlayer.stop() }
    }

    func pausePreview() {
        isPreviewPlaying = false
        playerQueue.async { [previewPlayer] in previewPlayer.pause() }
    }

    func resumePreview() {
        isPreviewPlaying = true
        playerQueue.async { [previewPlayer] in previewPlayer.play() }
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

    /// Reads `frameCount` frames from `file` (at its current framePosition), downmixes to mono,
    /// then packs that mono signal into a stereo buffer with signal only in `outputChannel`.
    private nonisolated static func buildChannelBuffer(file: AVAudioFile,
                                                       frameCount: AVAudioFrameCount,
                                                       outputChannel: OutputChannel,
                                                       playerFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let fileFormat = file.processingFormat

        // Read the source audio.
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat,
                                                   frameCapacity: frameCount) else {
            throw BufferError.allocationFailed
        }
        try file.read(into: sourceBuffer)

        // Downmix to mono at the player's sample rate.
        let sampleRate  = playerFormat.sampleRate
        let monoFormat  = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let monoBuffer  = try downmixToMono(source: sourceBuffer,
                                             fileFormat: fileFormat,
                                             monoFormat: monoFormat)

        // Build a stereo buffer: signal in the target channel, silence in the other.
        let frames = monoBuffer.frameLength
        guard let stereoBuffer = AVAudioPCMBuffer(pcmFormat: playerFormat,
                                                   frameCapacity: frames) else {
            throw BufferError.allocationFailed
        }
        stereoBuffer.frameLength = frames

        let src   = monoBuffer.floatChannelData![0]
        let left  = stereoBuffer.floatChannelData![0]
        let right = stereoBuffer.floatChannelData![1]

        switch outputChannel {
        case .left:
            for i in 0..<Int(frames) { left[i] = src[i]; right[i] = 0 }
        case .right:
            for i in 0..<Int(frames) { left[i] = 0;      right[i] = src[i] }
        case .both:
            for i in 0..<Int(frames) { left[i] = src[i]; right[i] = src[i] }
        }

        return stereoBuffer
    }

    /// Downmixes `source` to mono at `monoFormat.sampleRate`.
    ///
    /// Channel averaging is done manually before any sample-rate conversion so that
    /// AVAudioConverter only ever sees a mono→mono job. Relying on AVAudioConverter
    /// for channel reduction is unreliable: with no explicit mixing matrix it takes
    /// only channel 0, silently discarding all other channels.
    private nonisolated static func downmixToMono(source: AVAudioPCMBuffer,
                                                   fileFormat: AVAudioFormat,
                                                   monoFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        // Fast path: already mono at the right rate.
        if fileFormat.channelCount == 1 && fileFormat.sampleRate == monoFormat.sampleRate {
            return source
        }

        let frameCount   = source.frameLength
        let channelCount = Int(fileFormat.channelCount)

        // Step 1: Average all input channels into a mono buffer at the source sample rate.
        let srcMonoFormat = AVAudioFormat(standardFormatWithSampleRate: fileFormat.sampleRate, channels: 1)!
        guard let srcMono = AVAudioPCMBuffer(pcmFormat: srcMonoFormat, frameCapacity: frameCount) else {
            throw BufferError.allocationFailed
        }
        srcMono.frameLength = frameCount
        let dst = srcMono.floatChannelData![0]
        if channelCount == 1 {
            let src = source.floatChannelData![0]
            for i in 0..<Int(frameCount) { dst[i] = src[i] }
        } else {
            let scale = 1.0 / Float(channelCount)
            for i in 0..<Int(frameCount) { dst[i] = 0 }
            for ch in 0..<channelCount {
                let src = source.floatChannelData![ch]
                for i in 0..<Int(frameCount) { dst[i] += src[i] * scale }
            }
        }

        // Fast path: no sample-rate conversion needed.
        if fileFormat.sampleRate == monoFormat.sampleRate {
            return srcMono
        }

        // Step 2: Sample-rate convert mono→mono (AVAudioConverter handles this correctly).
        guard let converter = AVAudioConverter(from: srcMonoFormat, to: monoFormat) else {
            throw BufferError.conversionFailed
        }
        let ratio    = monoFormat.sampleRate / fileFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 1
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else {
            throw BufferError.allocationFailed
        }
        var consumed = false
        var convErr: NSError?
        converter.convert(to: mono, error: &convErr) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData
            return srcMono
        }
        if let e = convErr { throw e }
        return mono
    }
}

// MARK: - Buffer Slicing

extension AVAudioPCMBuffer {
    /// Returns a new buffer containing frames [startFrame, frameLength).
    ///
    /// This is a fast memcpy of the in-memory float data — no disk I/O.
    /// Returns nil if startFrame is out of range or allocation fails.
    func sliced(fromFrame startFrame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard startFrame >= 0,
              startFrame < AVAudioFramePosition(frameLength),
              let src = floatChannelData else { return nil }
        let remaining = AVAudioFrameCount(AVAudioFramePosition(frameLength) - startFrame)
        guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining),
              let dst = slice.floatChannelData else { return nil }
        slice.frameLength = remaining
        let bytesPerFrame = MemoryLayout<Float>.size
        for ch in 0..<Int(format.channelCount) {
            memcpy(dst[ch], src[ch].advanced(by: Int(startFrame)), Int(remaining) * bytesPerFrame)
        }
        return slice
    }
}
