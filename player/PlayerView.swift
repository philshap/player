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

        return VStack(spacing: 8) {
            Label("Main Output (L)", systemImage: "speaker.wave.2.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Track info
            if let track = main.currentTrack {
                VStack(spacing: 2) {
                    Text(track.title)
                        .font(.title3)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("No track loaded")
                    .foregroundStyle(.secondary)
            }

            // Seek bar
            HStack(spacing: 6) {
                Text(formatTime(main.currentTime))
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

                Text(formatTime(main.duration))
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

                Button { main.togglePlayPause() } label: {
                    Image(systemName: main.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)

                Button { main.nextTrack() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)

                Button { main.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Preview/Cue Section

    private var previewSection: some View {
        let preview = appState.previewPlayback

        return VStack(spacing: 8) {
            Label("Preview/Cue (R)", systemImage: "headphones")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Track info
            if let track = preview.currentTrack {
                VStack(spacing: 2) {
                    Text(track.title)
                        .font(.title3)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("No track loaded")
                    .foregroundStyle(.secondary)
            }

            // Seek bar
            HStack(spacing: 6) {
                Text(formatTime(preview.currentTime))
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

                Text(formatTime(preview.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
            }

            // Transport controls and volume
            HStack(spacing: 16) {
                Button { try? preview.togglePlayPause() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)

                Button { preview.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)

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
                    .frame(width: 100)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
