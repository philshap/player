//
//  WaveformSeekBar.swift
//  player
//

import SwiftUI

/// Waveform visualization that doubles as a seek/scrub control.
///
/// Renders a symmetric waveform with the played portion tinted in the accent color
/// and the unplayed portion dimmed. Supports drag-to-seek with the same
/// `onBeginSeek` / `onSeek` / `onEndSeek` callback pattern as the native Slider.
struct WaveformSeekBar: View {
    let waveformData: WaveformData?
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onBeginSeek: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onEndSeek: () -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                render(context: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = (value.location.x / proxy.size.width).clamped(to: 0...1)
                        let time = fraction * max(duration, 0.01)
                        if !isDragging {
                            isDragging = true
                            onBeginSeek()
                        }
                        onSeek(time)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEndSeek()
                    }
            )
        }
        .frame(height: 44)
    }

    private func render(context: GraphicsContext, size: CGSize) {
        let midY      = size.height / 2
        let maxAmp    = midY * 0.88
        let minHalf   : CGFloat = 1.5
        let fraction  : CGFloat = duration > 0 ? CGFloat(currentTime / duration) : 0
        let playheadX = (fraction * size.width).clamped(to: 0...size.width)

        guard let data = waveformData else {
            // Loading placeholder: thin horizontal rule
            var p = Path()
            p.move(to: CGPoint(x: 0, y: midY))
            p.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(p, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            return
        }

        let binCount = data.peaks.count
        let binWidth = size.width / CGFloat(binCount)
        let barWidth = max(binWidth * 0.75, 1.0)

        for bin in 0..<binCount {
            let cx   = (CGFloat(bin) + 0.5) * binWidth
            let half = max(CGFloat(data.peaks[bin]) * maxAmp, minHalf)
            let rect = CGRect(x: cx - barWidth / 2, y: midY - half, width: barWidth, height: half * 2)
            let color: Color = cx <= playheadX ? .accentColor : .secondary.opacity(0.35)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
        }

        // Playhead line
        if duration > 0 {
            var line = Path()
            line.move(to: CGPoint(x: playheadX, y: 0))
            line.addLine(to: CGPoint(x: playheadX, y: size.height))
            context.stroke(line, with: .color(.primary.opacity(0.75)), lineWidth: 1.5)
        }
    }
}
