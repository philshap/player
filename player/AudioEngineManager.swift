@preconcurrency import AVFoundation
import Observation

/// Shared AVAudioEngine host for the app's playback controllers.
///
/// Each `PlaybackController` owns its own `AVAudioPlayerNode` + `AVAudioMixerNode`
/// (player→mixer→mainMixer) and performs all transport directly on those nodes.
/// This manager holds only the resources that must be shared across controllers:
/// the engine instance, the buffer format, the serial dispatch queue used for
/// all player-node operations, and the hardware configuration-change observer.
///
/// Controllers register themselves at init time; `handleEngineConfigurationChange`
/// fans out to each registered controller so they can reset their playing flag and
/// re-establish their graph connections with the new format.
///
/// All playback is buffer-based (files pre-loaded into `AVAudioPCMBuffer`) to
/// eliminate disk I/O on the audio render thread and enable seamless gapless
/// chaining between tracks.
@Observable
final class AudioEngineManager {

    // MARK: - Types

    /// Which output channel(s) a buffer should carry signal in.
    /// `.left` and `.right` zero the opposite channel for mono-split routing.
    /// `.both` places the signal in both channels (stereo headphone monitoring).
    enum OutputChannel { case left, right, both }

    enum BufferError: Error {
        case allocationFailed
        case conversionFailed
        case invalidRange
    }

    // MARK: - Engine

    @ObservationIgnored let engine = AVAudioEngine()

    /// Serial queue for all AVAudioPlayerNode operations.
    ///
    /// AVAudioPlayerNode.stop/play/scheduleBuffer synchronise internally with
    /// AVFoundation infrastructure that runs at Default QoS. Calling them from
    /// the main actor (User-Interactive QoS) causes priority inversion warnings.
    /// Dispatching to this queue keeps the caller non-blocking and ensures the
    /// operations execute at a priority that matches AVFoundation's own threads.
    @ObservationIgnored let playerQueue = DispatchQueue(label: "com.player.audioengine", qos: .default)

    // MARK: - Buffer Format

    /// The PCM format used for all player-node buffer scheduling.
    /// Derived from the engine's hardware output; all loaded buffers are converted to this.
    private(set) var playerFormat: AVAudioFormat!

    // MARK: - Registry

    /// Weak references to attached controllers, so config changes can fan out.
    @ObservationIgnored private var controllers: [WeakBox<PlaybackController>] = []

    @ObservationIgnored private var configChangeObserver: (any NSObjectProtocol)?

    // MARK: - Init / Teardown

    init() {
        refreshPlayerFormat()
        observeConfigurationChanges()
    }

    deinit {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        engine.stop()
    }

    // MARK: - Engine Setup

    private func refreshPlayerFormat() {
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)

        // Always use explicit 2-channel stereo regardless of what the engine reports.
        // Channel isolation is enforced by the buffer content (L=signal/R=0 for main,
        // L=0/R=signal for preview) rather than by AVAudioMixerNode.pan, which is
        // unreliable across hardware configurations and macOS versions.
        playerFormat = AVAudioFormat(
            standardFormatWithSampleRate: max(outputFormat.sampleRate, 44_100),
            channels: 2
        )
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
    /// Reconnects each controller's nodes with the new hardware format and restarts the engine.
    private func handleEngineConfigurationChange() {
        if engine.isRunning { engine.stop() }
        refreshPlayerFormat()

        // Players lose their scheduled data when the engine stops; have each
        // controller mark itself stopped and reconnect its graph with the new format.
        for box in controllers {
            box.value?.handleEngineConfigurationChange()
        }

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
        engine.stop()
    }

    /// Starts the engine if it isn't already running. Safe to call from transport methods.
    func ensureRunning() throws {
        if !engine.isRunning { try engine.start() }
    }

    // MARK: - Controller Registry

    /// Attaches `player` + `mixer` to the engine graph, connects them through to the
    /// main mixer, and records the controller for configuration-change fan-out.
    /// Called once per `PlaybackController` during its init.
    func attach(_ controller: PlaybackController,
                player: AVAudioPlayerNode,
                mixer: AVAudioMixerNode) {
        engine.attach(player)
        engine.attach(mixer)
        connect(player: player, mixer: mixer)
        controllers.append(WeakBox(controller))
    }

    /// Re-establishes the player→mixer→mainMixer connections using the current
    /// `playerFormat`. Called by controllers during configuration-change recovery.
    func connect(player: AVAudioPlayerNode, mixer: AVAudioMixerNode) {
        engine.connect(player, to: mixer,             format: playerFormat)
        engine.connect(mixer,  to: engine.mainMixerNode, format: playerFormat)
    }

    // MARK: - Buffer Loading

    /// Background-safe full-file loader. Capture `audioEngine.playerFormat` before entering a Task.
    nonisolated static func loadBuffer(url: URL, outputChannel: OutputChannel,
                                       playerFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        return try loadBuffer(url: url, fromFrame: 0, outputChannel: outputChannel, playerFormat: playerFormat)
    }

    /// Background-safe loader with optional start and end frames for cue point support.
    nonisolated static func loadBuffer(url: URL,
                                       fromFrame startFrame: AVAudioFramePosition = 0,
                                       toFrame endFrame: AVAudioFramePosition? = nil,
                                       outputChannel: OutputChannel,
                                       playerFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard startFrame >= 0 && startFrame < file.length else { throw BufferError.invalidRange }

        file.framePosition = startFrame
        let actualEndFrame = endFrame ?? file.length
        guard actualEndFrame > startFrame && actualEndFrame <= file.length else {
            throw BufferError.invalidRange
        }

        let frameCount = AVAudioFrameCount(actualEndFrame - startFrame)
        return try buildChannelBuffer(file: file,
                                      frameCount: frameCount,
                                      outputChannel: outputChannel,
                                      playerFormat: playerFormat)
    }

    // MARK: - Private Helpers

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

// MARK: - Weak Box

private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
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

    /// Returns a new buffer containing exactly `length` frames starting at `startFrame`.
    ///
    /// This is a fast memcpy of the in-memory float data — no disk I/O.
    /// Returns nil if the range is out of bounds or allocation fails.
    func sliced(fromFrame startFrame: AVAudioFramePosition, length: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard startFrame >= 0,
              length > 0,
              startFrame + AVAudioFramePosition(length) <= AVAudioFramePosition(frameLength),
              let src = floatChannelData else { return nil }
        guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let dst = slice.floatChannelData else { return nil }
        slice.frameLength = length
        let bytesPerFrame = MemoryLayout<Float>.size
        for ch in 0..<Int(format.channelCount) {
            memcpy(dst[ch], src[ch].advanced(by: Int(startFrame)), Int(length) * bytesPerFrame)
        }
        return slice
    }
}
