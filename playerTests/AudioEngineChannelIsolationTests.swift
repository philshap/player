//
//  AudioEngineChannelIsolationTests.swift
//  playerTests
//
//  Verifies that AudioEngineManager.loadBuffer correctly routes signal to the
//  requested output channel (left for main, right for preview). Tests inspect
//  PCM sample values directly — no audio hardware or engine required.
//

import Testing
@testable import player
@preconcurrency import AVFoundation

// MARK: - Signal helpers

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

/// Writes a PCMBuffer to a temporary CAF file and returns the URL.
private func writeWAV(_ buffer: AVAudioPCMBuffer) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
    let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
    try file.write(from: buffer)
    return url
}

/// Returns a stereo buffer where both channels equal `value` (DC signal).
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

// MARK: - Tests

@Suite("AudioEngine channel isolation")
struct AudioEngineChannelIsolationTests {

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
}
