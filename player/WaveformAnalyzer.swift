//
//  WaveformAnalyzer.swift
//  player
//

@preconcurrency import AVFoundation

/// Downsampled peak data for waveform rendering.
struct WaveformData: Sendable {
    /// Per-bin peak amplitudes, normalized to 0...1.
    let peaks: [Float]
}

enum WaveformAnalyzer {

    nonisolated static let defaultBinCount = 1200

    /// Analyzes `buffer` between `startFrame` and `endFrame` and returns `binCount` peak values.
    ///
    /// Reads only the signal channel (determined by `outputChannel`). Peaks are normalized
    /// so the loudest bin reaches 1.0. Runs synchronously — always call from a background task.
    nonisolated static func analyze(
        buffer: AVAudioPCMBuffer,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        binCount: Int = defaultBinCount,
        outputChannel: AudioEngineManager.OutputChannel
    ) -> WaveformData {
        let frameCount = endFrame - startFrame
        guard binCount > 0,
              frameCount > 0,
              let channelData = buffer.floatChannelData else {
            return WaveformData(peaks: Array(repeating: 0, count: max(binCount, 1)))
        }

        // Main output carries signal in channel 0 (left); preview in channel 1 (right).
        let channelIndex: Int
        switch outputChannel {
        case .left, .both: channelIndex = 0
        case .right:        channelIndex = 1
        }
        let samples = channelData[channelIndex]

        let framesPerBin = Double(frameCount) / Double(binCount)
        var peaks = [Float](repeating: 0, count: binCount)

        for bin in 0..<binCount {
            let binStart = Int(startFrame) + Int(Double(bin) * framesPerBin)
            let binEnd   = min(Int(startFrame) + Int(Double(bin + 1) * framesPerBin), Int(endFrame))
            var peak: Float = 0
            for i in binStart..<binEnd {
                let v = abs(samples[i])
                if v > peak { peak = v }
            }
            peaks[bin] = peak
        }

        // Normalize so the loudest bin reaches 1.0.
        if let maxPeak = peaks.max(), maxPeak > 0 {
            let inv = 1.0 / maxPeak
            for i in peaks.indices { peaks[i] *= inv }
        }

        return WaveformData(peaks: peaks)
    }
}
