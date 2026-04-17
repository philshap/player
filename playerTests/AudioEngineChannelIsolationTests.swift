//
//  AudioEngineChannelIsolationTests.swift
//  playerTests
//
//  Verifies that the mono-split audio graph routes main playback exclusively to
//  the left channel and preview/cue playback exclusively to the right channel.
//
//  Uses AVAudioEngine's offline (manual) rendering mode so no audio hardware
//  is required and the output PCM samples can be inspected directly.
//

import Testing
@testable import player
@preconcurrency import AVFoundation

// MARK: - Graph builder

/// Builds the same player→mixer→mainMixerNode graph used by AudioEngineManager,
/// configured for offline rendering so tests can inspect rendered PCM samples.
/// Channel isolation is enforced by the buffer content (L=signal/R=0 for main,
/// L=0/R=signal for preview) — no pan settings are used.
private struct OfflineGraph {

    let engine        = AVAudioEngine()
    let mainPlayer    = AVAudioPlayerNode()
    let previewPlayer = AVAudioPlayerNode()
    let stereoFormat: AVAudioFormat

    init(sampleRate: Double = 44_100) throws {
        stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        let mainMixer    = AVAudioMixerNode()
        let previewMixer = AVAudioMixerNode()

        for node in [mainPlayer, previewPlayer, mainMixer, previewMixer] {
            engine.attach(node)
        }

        // All-stereo connections; no pan. Channel routing is in the buffer content.
        engine.connect(mainPlayer,    to: mainMixer,            format: stereoFormat)
        engine.connect(previewPlayer, to: previewMixer,         format: stereoFormat)
        engine.connect(mainMixer,     to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(previewMixer,  to: engine.mainMixerNode, format: stereoFormat)

        try engine.enableManualRenderingMode(
            .offline,
            format: stereoFormat,
            maximumFrameCount: 4_096
        )
        try engine.start()
        mainPlayer.play()
        previewPlayer.play()
    }

    /// Renders `frameCount` frames and returns the stereo output buffer.
    func render(frameCount: AVAudioFrameCount = 512) throws -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frameCount)!
        let status = try engine.renderOffline(frameCount, to: out)
        guard status == .success else {
            throw RenderError.failed(status)
        }
        return out
    }

    enum RenderError: Error {
        case failed(AVAudioEngineManualRenderingStatus)
    }
}

// MARK: - Signal helpers

/// Returns a mono buffer where every sample equals `value` (DC signal).
private func dcBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount = 512,
                      value: Float = 1.0) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buf.frameLength = frameCount
    let ch = buf.floatChannelData![0]
    for i in 0..<Int(frameCount) { ch[i] = value }
    return buf
}

/// Root-mean-square energy of a channel pointer.
private func rms(_ ptr: UnsafePointer<Float>, count: Int) -> Float {
    guard count > 0 else { return 0 }
    let sum = (0..<count).reduce(Float(0)) { $0 + ptr[$1] * ptr[$1] }
    return sqrt(sum / Float(count))
}

/// Writes a PCMBuffer to a temporary CAF file and returns the URL.
/// Callers are responsible for the file lifetime; temp files are cleaned up by the OS.
private func writeWAV(_ buffer: AVAudioPCMBuffer) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
    let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
    try file.write(from: buffer)
    return url
}

/// Arithmetic mean of a channel pointer.
private func mean(_ ptr: UnsafePointer<Float>, count: Int) -> Float {
    guard count > 0 else { return 0 }
    return (0..<count).reduce(Float(0)) { $0 + ptr[$1] } / Float(count)
}

/// Returns a stereo buffer where both channels equal `value` (simulates a stereo audio file).
private func stereoDCBuffer(sampleRate: Double = 44_100, frameCount: AVAudioFrameCount = 512,
                             value: Float = 1.0) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
    buf.frameLength = frameCount
    for ch in 0..<2 {
        let ptr = buf.floatChannelData![ch]
        for i in 0..<Int(frameCount) { ptr[i] = value }
    }
    return buf
}

/// Downmixes a stereo buffer to mono by averaging L and R — no AVAudioConverter needed.
/// Uses the same result as a perfect L+R mix, which is what real music files contain.
private func downmixToMono(_ source: AVAudioPCMBuffer,
                            monoFormat: AVAudioFormat) -> AVAudioPCMBuffer {
    let frameCount = source.frameLength
    let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount)!
    out.frameLength = frameCount
    let outCh = out.floatChannelData![0]
    let inL   = source.floatChannelData![0]
    let inR   = source.floatChannelData![1]
    for i in 0..<Int(frameCount) {
        outCh[i] = (inL[i] + inR[i]) * 0.5
    }
    return out
}

// MARK: - Tests

@Suite("AudioEngine channel isolation")
struct AudioEngineChannelIsolationTests {

    // ── Buffer construction (no hardware/engine needed) ───────────────────
    // These tests verify AudioEngineManager.loadBuffer directly by inspecting
    // the PCM sample values, confirming channel assignment before any audio
    // engine involvement.

    @Test func mainBufferHasSignalOnlyInLeftChannel() throws {
        let fmt    = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let stereo = stereoDCBuffer(value: 1.0)
        let buf    = try AudioEngineManager.loadBuffer(
            url: writeWAV(stereo),
            outputChannel: .left,
            playerFormat: fmt
        )
        let n        = Int(buf.frameLength)
        let leftRMS  = rms(buf.floatChannelData![0], count: n)
        let rightRMS = rms(buf.floatChannelData![1], count: n)
        #expect(leftRMS  > 0.1,   "Main buffer must carry signal in left channel")
        #expect(rightRMS < 0.001, "Main buffer must have silence in right channel")
    }

    @Test func previewBufferHasSignalOnlyInRightChannel() throws {
        let fmt    = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let stereo = stereoDCBuffer(value: 1.0)
        let buf    = try AudioEngineManager.loadBuffer(
            url: writeWAV(stereo),
            outputChannel: .right,
            playerFormat: fmt
        )
        let n        = Int(buf.frameLength)
        let leftRMS  = rms(buf.floatChannelData![0], count: n)
        let rightRMS = rms(buf.floatChannelData![1], count: n)
        #expect(leftRMS  < 0.001, "Preview buffer must have silence in left channel")
        #expect(rightRMS > 0.1,   "Preview buffer must carry signal in right channel")
    }

    @Test func oppositePolarityBuffersDontCancel() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let mainBuf    = try AudioEngineManager.loadBuffer(url: writeWAV(stereoDCBuffer(value:  1.0)),
                                                           outputChannel: .left,  playerFormat: fmt)
        let previewBuf = try AudioEngineManager.loadBuffer(url: writeWAV(stereoDCBuffer(value: -1.0)),
                                                           outputChannel: .right, playerFormat: fmt)
        let n = Int(mainBuf.frameLength)
        #expect(mean(mainBuf.floatChannelData![0],    count: n) >  0.1)
        #expect(mean(mainBuf.floatChannelData![1],    count: n).magnitude < 0.001)
        #expect(mean(previewBuf.floatChannelData![0], count: n).magnitude < 0.001)
        #expect(mean(previewBuf.floatChannelData![1], count: n) < -0.1)
    }

    // ── End-to-end rendering (offline engine) ─────────────────────────────
    // These tests verify the complete path: pre-built buffers → player nodes →
    // mixers → mainMixerNode, confirming channel isolation survives the graph.

    @Test func mainPlayerOutputIsolatedToLeftInRenderedAudio() throws {
        let graph  = try OfflineGraph()
        let stereo = stereoDCBuffer(sampleRate: 44_100, value: 1.0)
        let buf    = try AudioEngineManager.loadBuffer(url: writeWAV(stereo),
                                                       outputChannel: .left,
                                                       playerFormat: graph.stereoFormat)
        graph.mainPlayer.scheduleBuffer(buf)
        let output   = try graph.render()
        let n        = Int(output.frameLength)
        #expect(rms(output.floatChannelData![0], count: n) > 0.1,   "Left should carry main signal")
        #expect(rms(output.floatChannelData![1], count: n) < 0.001, "Right should be silent")
    }

    @Test func previewPlayerOutputIsolatedToRightInRenderedAudio() throws {
        let graph  = try OfflineGraph()
        let stereo = stereoDCBuffer(sampleRate: 44_100, value: 1.0)
        let buf    = try AudioEngineManager.loadBuffer(url: writeWAV(stereo),
                                                       outputChannel: .right,
                                                       playerFormat: graph.stereoFormat)
        graph.previewPlayer.scheduleBuffer(buf)
        let output   = try graph.render()
        let n        = Int(output.frameLength)
        #expect(rms(output.floatChannelData![0], count: n) < 0.001, "Left should be silent")
        #expect(rms(output.floatChannelData![1], count: n) > 0.1,   "Right should carry preview signal")
    }

    @Test func bothPlayersDoNotCrossContaminateInRenderedAudio() throws {
        let graph      = try OfflineGraph()
        let mainBuf    = try AudioEngineManager.loadBuffer(url: writeWAV(stereoDCBuffer(value:  1.0)),
                                                           outputChannel: .left,
                                                           playerFormat: graph.stereoFormat)
        let previewBuf = try AudioEngineManager.loadBuffer(url: writeWAV(stereoDCBuffer(value: -1.0)),
                                                           outputChannel: .right,
                                                           playerFormat: graph.stereoFormat)
        graph.mainPlayer.scheduleBuffer(mainBuf)
        graph.previewPlayer.scheduleBuffer(previewBuf)
        let output = try graph.render()
        let n      = Int(output.frameLength)
        #expect(mean(output.floatChannelData![0], count: n) >  0.1, "Left carries main (+1.0)")
        #expect(mean(output.floatChannelData![1], count: n) < -0.1, "Right carries preview (-1.0)")
    }

    @Test func silentPlayersProduceSilentOutput() throws {
        let graph  = try OfflineGraph()
        let output = try graph.render()
        let n      = Int(output.frameLength)
        #expect(rms(output.floatChannelData![0], count: n) < 0.001)
        #expect(rms(output.floatChannelData![1], count: n) < 0.001)
    }
}
