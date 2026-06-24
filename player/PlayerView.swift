//
//  PlayerView.swift
//  player
//

import SwiftUI
import AppKit

// MARK: - Artwork Color Extraction

private extension NSImage {
    /// Extracts the dominant saturated hue from the image using a 16×16
    /// downsample and a 36-bucket hue histogram. Falls back to nil if the
    /// image is mostly grey/black.
    func dominantAccentColor() -> NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var raw = [UInt8](repeating: 0, count: 16 * 16 * 4)
        guard let ctx = CGContext(
            data: &raw, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 16))

        var buckets = [Int](repeating: 0, count: 36)
        var satAcc  = [CGFloat](repeating: 0, count: 36)
        var briAcc  = [CGFloat](repeating: 0, count: 36)

        for i in 0..<(16 * 16) {
            let r = CGFloat(raw[i*4])   / 255
            let g = CGFloat(raw[i*4+1]) / 255
            let b = CGFloat(raw[i*4+2]) / 255
            let hi = max(r, g, b), lo = min(r, g, b)
            let delta = hi - lo
            guard delta > 0.15, hi > 0.1 else { continue }
            var h: CGFloat
            if hi == r      { h = (g - b) / delta }
            else if hi == g { h = 2 + (b - r) / delta }
            else            { h = 4 + (r - g) / delta }
            h = (h / 6).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
            let bucket = Int(h * 36) % 36
            buckets[bucket] += 1
            satAcc[bucket] += delta / hi
            briAcc[bucket] += hi
        }

        guard let (idx, cnt) = buckets.enumerated()
                                .max(by: { $0.element < $1.element }),
              cnt > 0 else { return nil }

        let c = CGFloat(cnt)
        return NSColor(
            hue:        CGFloat(idx) / 36,
            saturation: max(0.55, satAcc[idx] / c),
            brightness: max(0.65, briAcc[idx] / c),
            alpha:      1
        )
    }
}

// MARK: - Tint Color Helpers

/// Extracts a tint Color from album artwork, falling back to a hash-based hue.
private func tintColor(for track: Track?) -> Color {
    guard let track else { return .accentColor }
    if let data = track.artworkData,
       let image = NSImage(data: data),
       let nsColor = image.dominantAccentColor() {
        return Color(nsColor)
    }
    var v: UInt64 = 14695981039346656037
    for c in (track.title + track.artist).unicodeScalars {
        v ^= UInt64(c.value)
        v = v &* 1099511628211
    }
    return Color(hue: Double(v % 360) / 360.0, saturation: 0.58, brightness: 0.84)
}

// MARK: - BPM Badge

private struct BPMBadge: View {
    let bpm: Double?
    let tint: Color

    var body: some View {
        if let bpm {
            HStack(spacing: 2) {
                Text(String(Int(bpm.rounded())))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.9))
                Text("BPM")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.5))
            }
        }
    }
}

// MARK: - Level Meter Strip

private struct LevelMeterStrip: View {
    let tint: Color
    let level: Float

    private let segmentCount = 14

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<segmentCount, id: \.self) { i in
                let fraction = Double(i) / Double(segmentCount - 1)
                let lit = Double(level) > fraction
                Capsule()
                    .fill(segColor(fraction: fraction, lit: lit))
                    .frame(height: 4)
            }
        }
    }

    private func segColor(fraction: Double, lit: Bool) -> Color {
        guard lit else { return Color.secondary.opacity(0.2) }
        if fraction > 0.85 { return Color(red: 1.0, green: 0.35, blue: 0.29) }
        if fraction > 0.65 { return Color(red: 0.91, green: 0.70, blue: 0.29) }
        return tint
    }
}

// MARK: - Circular Transport Button

private struct TransportButton: View {
    let icon: String
    let action: () -> Void
    var isPrimary: Bool = false
    var size: CGFloat = 34
    var tint: Color = .accentColor
    var isDisabled: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isPrimary ? tint : Color.white.opacity(0.12))
                    .shadow(color: isPrimary ? tint.opacity(0.45) : .clear, radius: 7, y: 2)
                Image(systemName: icon)
                    .font(.system(size: size * 0.33, weight: .medium))
                    .foregroundStyle(isPrimary
                        ? Color.black.opacity(0.82)
                        : Color.primary.opacity(0.75))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.38 : 1)
        .focusable(false)
    }
}

// MARK: - Channel Header

private struct ChannelHeader: View {
    let systemImage: String
    let label: String
    let tint: Color
    var showMeter: Bool = false
    var meterLevel: Float = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.7))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.78))
            Spacer()
            if showMeter {
                LevelMeterStrip(tint: tint, level: meterLevel)
                    .frame(width: 84)
            }
        }
        .frame(height: 22)
    }
}

// MARK: - Up Next Card

private struct UpNextCard: View {
    let track: Track?
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Up Next")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.55))
                .kerning(0.8)
                .textCase(.uppercase)

            if let track {
                HStack(spacing: 10) {
                    TrackArtworkView(data: track.artworkData, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !track.artist.isEmpty {
                            Text(track.artist)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary.opacity(0.65))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    BPMBadge(bpm: track.bpm, tint: tint)
                }
            } else {
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.black.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Deck Waveform Background

// MARK: - Main View

struct PlayerView: View {
    @Environment(AppState.self) private var appState

    /// Cached tints — recomputed only when the loaded track changes, not on every render.
    @State private var mainTint:    Color = .accentColor
    @State private var previewTint: Color = .accentColor

    private let mainDeckHeight:    CGFloat = 162
    private let previewDeckHeight: CGFloat = 108

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MainDeckView(
                    controller: appState.mainPlayback,
                    tint: mainTint,
                    isPerformanceMode: appState.isPerformanceMode
                )
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 16)

                Divider()
                    .opacity(0.35)

                PreviewDeckView(
                    controller: appState.previewPlayback,
                    tint: previewTint
                )
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .frame(minWidth: 520, minHeight: 380)
            .navigationTitle(appState.isPerformanceMode ? "Player — Performance" : "Player")
            .preferredColorScheme(.dark)
        }
        .task(id: appState.mainPlayback.currentTrack?.id) {
            mainTint = tintColor(for: appState.mainPlayback.currentTrack)
        }
        .task(id: appState.previewPlayback.currentTrack?.id) {
            previewTint = tintColor(for: appState.previewPlayback.currentTrack)
        }
    }
}

// MARK: - Helpers

private func waveformLevel(_ controller: some PlaybackController) -> Float {
    guard let data = controller.waveformData,
          !data.peaks.isEmpty,
          controller.duration > 0 else { return 0 }
    let fraction = controller.currentTime / controller.duration
    let idx = Int(fraction * Double(data.peaks.count)).clamped(to: 0...(data.peaks.count - 1))
    return data.peaks[idx]
}

// MARK: - Main Deck

private struct MainDeckView: View {
    let controller: MainPlaybackController
    let tint: Color
    let isPerformanceMode: Bool

    private let height: CGFloat = 162

    var body: some View {
        let isStereo = controller.outputChannel == .both

        VStack(spacing: 8) {
            // Channel header (above the waveform block)
            HStack {
                ChannelHeader(
                    systemImage: "speaker.wave.2.fill",
                    label: isStereo ? "Main Output (L+R)" : "Main Output (L)",
                    tint: tint,
                    showMeter: true,
                    meterLevel: waveformLevel(controller)
                )
                Button {
                    controller.outputChannel = isStereo ? .left : .both
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.12))
                        Image(systemName: isStereo ? "speaker.2.fill" : "speaker.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(isStereo ? "Switch to left channel only" : "Switch to stereo output")
            }

            // Deck body — waveform fills full height, content overlaid
            ZStack {
                // Layer 0: waveform background (inset so time labels sit in the margins)
                WaveformSeekBar(
                    waveformData: controller.waveformData,
                    currentTime: controller.currentTime,
                    duration: max(controller.duration, 0.01),
                    tint: tint,
                    onBeginSeek: { controller.beginInteractiveSeek() },
                    onSeek: { controller.seek(to: $0) },
                    onEndSeek: { controller.endInteractiveSeek() }
                )
                .padding(.horizontal, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Layer 1: time labels at vertical center, in the left/right margins
                HStack {
                    Text(controller.currentTime.mmss())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tint)
                        .frame(width: 46, alignment: .trailing)
                    Spacer()
                    Text(controller.duration.mmss())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .frame(width: 46, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)

                // Layer 3: track info + controls
                VStack(spacing: 0) {
                    // Track info
                    HStack(alignment: .center, spacing: 14) {
                        TrackArtworkView(
                            data: controller.currentTrack?.artworkData,
                            size: 60
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            Text(controller.currentTrack?.title ?? "No track loaded")
                                .font(.system(size: 21, weight: .semibold))
                                .tracking(-0.3)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(controller.currentTrack != nil ? .primary : .secondary)
                            if let track = controller.currentTrack {
                                HStack(spacing: 8) {
                                    if !track.artist.isEmpty {
                                        Text(track.artist)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary.opacity(0.85))
                                            .lineLimit(1)
                                    }
                                    if track.bpm != nil {
                                        Text("·").foregroundStyle(.secondary.opacity(0.35))
                                    }
                                    BPMBadge(bpm: track.bpm, tint: tint)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if isPerformanceMode {
                            UpNextCard(track: controller.upcomingTrack, tint: tint)
                                .frame(width: 220)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                    Spacer(minLength: 0)

                    // Transport controls
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            TransportButton(
                                icon: "backward.fill",
                                action: { controller.previousTrack() },
                                size: 30, tint: tint
                            )
                            TransportButton(
                                icon: "arrow.counterclockwise",
                                action: { controller.seek(to: 0) },
                                size: 30, tint: tint,
                                isDisabled: controller.currentTrack == nil
                            )
                            TransportButton(
                                icon: controller.isPlaying ? "pause.fill" : "play.fill",
                                action: { controller.togglePlayPause() },
                                isPrimary: true, size: 40, tint: tint
                            )
                            TransportButton(
                                icon: "forward.fill",
                                action: { controller.nextTrack() },
                                size: 30, tint: tint
                            )
                            TransportButton(
                                icon: "stop.fill",
                                action: { controller.stop() },
                                size: 30, tint: tint
                            )
                            if isPerformanceMode {
                                Spacer().frame(width: 4)
                                GapPickerView(controller: controller)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Gap Picker (isolated observation to avoid re-rendering the whole deck)

private struct GapPickerView: View {
    let controller: MainPlaybackController

    var body: some View {
        if controller.isInGap {
            HStack(spacing: 4) {
                Text("Next in \(String(format: "%.0f", controller.gapRemaining))s")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .monospacedDigit()
                Button("Skip") { controller.nextTrack() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            }
        } else {
            Picker("After track", selection: Binding(
                get: { controller.pauseAfterTrack ? -1.0 as TimeInterval : controller.gapDuration },
                set: { value in
                    if value == -1.0 {
                        controller.pauseAfterTrack = true
                        controller.gapDuration = 0
                    } else {
                        controller.pauseAfterTrack = false
                        controller.gapDuration = value
                    }
                }
            )) {
                Text("No gap").tag(0.0 as TimeInterval)
                Text("1s").tag(1.0 as TimeInterval)
                Text("2s").tag(2.0 as TimeInterval)
                Text("3s").tag(3.0 as TimeInterval)
                Text("5s").tag(5.0 as TimeInterval)
                Divider()
                Text("Pause after track").tag(-1.0 as TimeInterval)
            }
            .fixedSize()
            .focusable(false)
        }
    }
}

// MARK: - Preview Deck

private struct PreviewDeckView: View {
    let controller: PreviewPlaybackController
    let tint: Color

    private let height: CGFloat = 108

    var body: some View {
        let isStereo = controller.outputChannel == .both

        VStack(spacing: 8) {
            // Channel header
            HStack {
                ChannelHeader(
                    systemImage: "headphones",
                    label: isStereo ? "Preview / Cue (L+R)" : "Preview / Cue (R)",
                    tint: tint
                )
                Button {
                    controller.outputChannel = isStereo ? .right : .both
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.12))
                        Image(systemName: isStereo ? "speaker.2.fill" : "speaker.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(isStereo ? "Switch to right channel only" : "Switch to stereo output")
            }

            // Deck body
            ZStack {
                // Layer 0: waveform background (inset so time labels sit in the margins)
                WaveformSeekBar(
                    waveformData: controller.waveformData,
                    currentTime: controller.currentTime,
                    duration: max(controller.duration, 0.01),
                    tint: tint,
                    onBeginSeek: { controller.beginInteractiveSeek() },
                    onSeek: { controller.seek(to: $0) },
                    onEndSeek: { controller.endInteractiveSeek() }
                )
                .padding(.horizontal, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Layer 1: time labels at vertical center, in the left/right margins
                HStack {
                    Text(controller.currentTime.mmss())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tint)
                        .frame(width: 46, alignment: .trailing)
                    Spacer()
                    Text(controller.duration.mmss())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .frame(width: 46, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)

                // Layer 3: content
                VStack(spacing: 0) {
                    // Track info
                    HStack(spacing: 12) {
                        TrackArtworkView(
                            data: controller.currentTrack?.artworkData,
                            size: 48
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(controller.currentTrack?.title ?? "No track loaded")
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(controller.currentTrack != nil ? .primary : .secondary)
                            if let track = controller.currentTrack {
                                HStack(spacing: 6) {
                                    if !track.artist.isEmpty {
                                        Text(track.artist)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary.opacity(0.7))
                                            .lineLimit(1)
                                    }
                                    if track.bpm != nil {
                                        Text("·").foregroundStyle(.secondary.opacity(0.35))
                                    }
                                    BPMBadge(bpm: track.bpm, tint: tint)
                                }
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 5))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                    Spacer(minLength: 0)

                    // Transport controls
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            TransportButton(
                                icon: controller.isPlaying ? "pause.fill" : "play.fill",
                                action: { controller.togglePlayPause() },
                                isPrimary: true, size: 32, tint: tint
                            )
                            TransportButton(
                                icon: "stop.fill",
                                action: { controller.stop() },
                                size: 32, tint: tint
                            )
                            Spacer()
                            HStack(spacing: 5) {
                                Image(systemName: "speaker.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary.opacity(0.55))
                                Slider(
                                    value: Binding(
                                        get: { Double(controller.volume) },
                                        set: { controller.volume = Float($0) }
                                    ),
                                    in: 0...1
                                )
                                .focusable(false)
                                .frame(width: 90)
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary.opacity(0.55))
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    .padding(.horizontal, 14)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
