//
//  WaveformSeekBar.swift
//  player
//

import SwiftUI

/// Waveform visualization that doubles as a seek/scrub control.
///
/// Renders a frequency-colored symmetric waveform: played bars use a gradient from
/// dark bass (bottom) → tint mids → warm highs (top); unplayed bars are the same
/// gradient at low opacity. Height is flexible — set it in the parent container.
struct WaveformSeekBar: View {
    let waveformData: WaveformData?
    let currentTime: TimeInterval
    let duration: TimeInterval
    var tint: Color = .accentColor
    let onBeginSeek: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onEndSeek: () -> Void

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0

    private var displayTime: TimeInterval { isDragging ? dragTime : currentTime }

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
                        dragTime = time
                        onSeek(time)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEndSeek()
                    }
            )
        }
    }

    private func render(context: GraphicsContext, size: CGSize) {
        let midY      = size.height / 2
        let maxAmp    = midY * 0.9
        let minHalf   : CGFloat = 1.5
        let fraction  : CGFloat = duration > 0 ? CGFloat(displayTime / duration) : 0
        let playheadX = (fraction * size.width).clamped(to: 0...size.width)

        guard let data = waveformData else {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: midY))
            p.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(p, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
            return
        }

        let binCount = data.peaks.count
        let binWidth = size.width / CGFloat(binCount)
        let barWidth = max(binWidth * 0.72, 1.0)

        // Frequency-colored gradient stops: bass (bottom) → tint (centre) → warm (top).
        // Both played and unplayed regions use the same stops; unplayed bars are drawn
        // at reduced opacity so they appear desaturated while keeping the hue.
        let bassColor = Color(red: 0.60, green: 0.29, blue: 0.17)
        let warmColor = Color(red: 0.91, green: 0.83, blue: 0.66)
        let playedOpacity:   CGFloat = 1.0
        let unplayedOpacity: CGFloat = 0.28

        for bin in 0..<binCount {
            let cx    = (CGFloat(bin) + 0.5) * binWidth
            let half  = max(CGFloat(data.peaks[bin]) * maxAmp, minHalf)
            let rect  = CGRect(x: cx - barWidth / 2,
                               y: midY - half,
                               width: barWidth,
                               height: half * 2)
            let path    = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            let played  = cx <= playheadX
            let opacity = played ? playedOpacity : unplayedOpacity

            var ctx = context
            ctx.opacity = opacity
            ctx.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: bassColor, location: 0.0),
                    .init(color: tint,      location: 0.38),
                    .init(color: tint,      location: 0.62),
                    .init(color: warmColor, location: 1.0),
                ]),
                startPoint: CGPoint(x: rect.midX, y: rect.maxY),
                endPoint:   CGPoint(x: rect.midX, y: rect.minY)
            ))
        }

        // Playhead line
        if duration > 0 {
            var line = Path()
            line.move(to:    CGPoint(x: playheadX, y: 0))
            line.addLine(to: CGPoint(x: playheadX, y: size.height))
            context.stroke(line, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
        }
    }
}
