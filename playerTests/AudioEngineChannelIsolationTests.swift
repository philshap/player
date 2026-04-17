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
@preconcurrency import AVFoundation

// MARK: - Graph builder

/// Builds the same player→mixer→mainMixerNode graph used by AudioEngineManager,
/// configured for offline rendering so tests can inspect rendered PCM samples.
private struct OfflineGraph {

    let engine        = AVAudioEngine()
    let mainPlayer    = AVAudioPlayerNode()
    let previewPlayer = AVAudioPlayerNode()
    let monoFormat:   AVAudioFormat
    let stereoFormat: AVAudioFormat

    init(sampleRate: Double = 44_100) throws {
        stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        monoFormat   = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let mainMixer    = AVAudioMixerNode()
        let previewMixer = AVAudioMixerNode()

        for node in [mainPlayer, previewPlayer, mainMixer, previewMixer] {
            engine.attach(node)
        }

        // Mono connections force a stereo→mono downmix before panning,
        // which is required for hard-pan to fully isolate channels.
        engine.connect(mainPlayer,    to: mainMixer,            format: monoFormat)
        engine.connect(previewPlayer, to: previewMixer,         format: monoFormat)
        engine.connect(mainMixer,     to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(previewMixer,  to: engine.mainMixerNode, format: stereoFormat)

        mainMixer.pan    = -1.0   // hard left  → main output
        previewMixer.pan =  1.0   // hard right → cue/preview output

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

/// Arithmetic mean of a channel pointer.
private func mean(_ ptr: UnsafePointer<Float>, count: Int) -> Float {
    guard count > 0 else { return 0 }
    return (0..<count).reduce(Float(0)) { $0 + ptr[$1] } / Float(count)
}

// MARK: - Tests

@Suite("AudioEngine channel isolation")
struct AudioEngineChannelIsolationTests {

    /// Scheduling a signal on the main player should produce output only in the
    /// left channel. The right channel must remain silent.
    @Test func mainPlayerIsIsolatedToLeftChannel() throws {
        let graph = try OfflineGraph()
        graph.mainPlayer.scheduleBuffer(dcBuffer(format: graph.monoFormat))

        let output  = try graph.render()
        let n       = Int(output.frameLength)
        let leftRMS = rms(output.floatChannelData![0], count: n)
        let rightRMS = rms(output.floatChannelData![1], count: n)

        #expect(leftRMS  > 0.1,   "Main player should produce signal in the left channel")
        #expect(rightRMS < 0.001, "Main player must not bleed into the right (cue) channel")
    }

    /// Scheduling a signal on the preview player should produce output only in
    /// the right channel. The left channel must remain silent.
    @Test func previewPlayerIsIsolatedToRightChannel() throws {
        let graph = try OfflineGraph()
        graph.previewPlayer.scheduleBuffer(dcBuffer(format: graph.monoFormat))

        let output   = try graph.render()
        let n        = Int(output.frameLength)
        let leftRMS  = rms(output.floatChannelData![0], count: n)
        let rightRMS = rms(output.floatChannelData![1], count: n)

        #expect(leftRMS  < 0.001, "Preview player must not bleed into the left (main) channel")
        #expect(rightRMS > 0.1,   "Preview player should produce signal in the right channel")
    }

    /// When both players run simultaneously with opposite-polarity signals,
    /// the left channel should be positive and the right channel negative,
    /// confirming there is no cross-contamination between the two paths.
    @Test func mainAndPreviewChannelsDoNotCrossContaminate() throws {
        let graph = try OfflineGraph()
        graph.mainPlayer.scheduleBuffer(dcBuffer(format: graph.monoFormat, value:  1.0))
        graph.previewPlayer.scheduleBuffer(dcBuffer(format: graph.monoFormat, value: -1.0))

        let output     = try graph.render()
        let n          = Int(output.frameLength)
        let leftMean   = mean(output.floatChannelData![0], count: n)
        let rightMean  = mean(output.floatChannelData![1], count: n)

        #expect(leftMean  >  0.1, "Left channel carries main (+1.0); mean must be positive")
        #expect(rightMean < -0.1, "Right channel carries preview (-1.0); mean must be negative")
    }

    /// Silence on both players should produce silence on both output channels.
    @Test func silentPlayersProduceSilentOutput() throws {
        let graph = try OfflineGraph()
        // Nothing scheduled — both players are silent.

        let output   = try graph.render()
        let n        = Int(output.frameLength)
        let leftRMS  = rms(output.floatChannelData![0], count: n)
        let rightRMS = rms(output.floatChannelData![1], count: n)

        #expect(leftRMS  < 0.001, "Left channel should be silent with no scheduled content")
        #expect(rightRMS < 0.001, "Right channel should be silent with no scheduled content")
    }
}
