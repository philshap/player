//
//  PlayerView.swift
//  player
//

import SwiftUI

struct PlayerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if appState.isPerformanceMode {
                HStack {
                    Image(systemName: "lock.fill")
                    Text("Performance Mode")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.orange)
                .padding(.vertical, 4)
            }

            // Main Playback Section
            mainPlaybackSection
                .padding()

            Divider()

            // Preview/Cue Section
            previewSection
                .padding()
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    // MARK: - Main Playback Section

    private var mainPlaybackSection: some View {
        let main = appState.mainPlayback
        let engine  = appState.audioEngine
        let isStereo = engine.mainOutputChannel == .both

        return VStack(spacing: 8) {
            HStack {
                Label(isStereo ? "Main Output (L+R)" : "Main Output (L)",
                      systemImage: "speaker.wave.2.fill")
                    .font(.headline)
                Spacer()
                Button {
                    engine.mainOutputChannel = isStereo ? .left : .both
                } label: {
                    Image(systemName: isStereo ? "speaker.2.fill" : "speaker.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(isStereo ? "Switch to left channel only (mono-split cable mode)"
                               : "Switch to stereo output (both channels)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Track info
            if let track = main.currentTrack {
                HStack {
                    TrackInfoView(track: track, artworkSize: 52, titleFont: .title3)
                    Spacer()
                }
            } else {
                Text("No track loaded")
                    .foregroundStyle(.secondary)
            }

            // Seek bar
            HStack(spacing: 6) {
                Text(main.currentTime.mmss())
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { main.currentTime },
                        set: { main.seek(to: $0) }
                    ),
                    in: 0...max(main.duration, 0.01)
                )
                .focusable(false)

                Text(main.duration.mmss())
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
            }

            // Transport controls
            HStack(spacing: 16) {
                Button { main.previousTrack() } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("Previous Track")

                Button { main.seek(to: 0) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .disabled(main.currentTrack == nil)
                .help("Restart Track")

                Button { main.togglePlayPause() } label: {
                    Image(systemName: main.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .focusable(false)

                Button { main.nextTrack() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .focusable(false)

                Button { main.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .focusable(false)
            }
        }
    }

    // MARK: - Preview/Cue Section

    private var previewSection: some View {
        let preview = appState.previewPlayback
        let engine  = appState.audioEngine
        let isStereo = engine.previewOutputChannel == .both

        return VStack(spacing: 8) {
            HStack {
                Label(isStereo ? "Preview/Cue (L+R)" : "Preview/Cue (R)",
                      systemImage: "headphones")
                    .font(.headline)
                Spacer()
                Button {
                    engine.previewOutputChannel = isStereo ? .right : .both
                } label: {
                    Image(systemName: isStereo ? "speaker.2.fill" : "speaker.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(isStereo ? "Switch to right channel only (mono-split cable mode)"
                               : "Switch to stereo output (both channels)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Track info
            if let track = preview.currentTrack {
                HStack {
                    TrackInfoView(track: track, artworkSize: 52, titleFont: .title3)
                    Spacer()
                }
            } else {
                Text("No track loaded")
                    .foregroundStyle(.secondary)
            }

            // Seek bar
            HStack(spacing: 6) {
                Text(preview.currentTime.mmss())
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { preview.currentTime },
                        set: { preview.seek(to: $0) }
                    ),
                    in: 0...max(preview.duration, 0.01)
                )
                .focusable(false)

                Text(preview.duration.mmss())
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
            }

            // Transport controls and volume
            HStack(spacing: 16) {
                Button { preview.togglePlayPause() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .focusable(false)

                Button { preview.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .focusable(false)

                Spacer()

                // Volume slider
                HStack(spacing: 4) {
                    Image(systemName: "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { preview.volume },
                            set: { preview.volume = $0 }
                        ),
                        in: 0...1
                    )
                    .focusable(false)
                    .frame(width: 100)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

}
