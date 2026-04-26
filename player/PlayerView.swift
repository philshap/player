//
//  PlayerView.swift
//  player
//

import SwiftUI

struct PlayerView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("waveformEnabled") private var waveformEnabled = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Main Playback Section
                mainPlaybackSection
                    .padding()

                Divider()

                // Preview/Cue Section
                previewSection
                    .padding()
            }
            .frame(minWidth: 500, minHeight: 300)
            .navigationTitle(playerWindowTitle)
        }
    }

    private var playerWindowTitle: String {
        appState.isPerformanceMode ? "Player - Performance" : "Player"
    }

    // MARK: - Main Playback Section

    private var mainPlaybackSection: some View {
        let main = appState.mainPlayback
        let isStereo = main.outputChannel == .both
        let isPerformance = appState.isPerformanceMode
        let artworkSize: CGFloat = isPerformance ? 72 : 52
        let titleFont: Font = isPerformance ? .title2 : .title3
        let upNextPanelWidth: CGFloat = 260

        return VStack(spacing: 8) {
            HStack {
                Label(isStereo ? "Main Output (L+R)" : "Main Output (L)",
                      systemImage: "speaker.wave.2.fill")
                    .font(.headline)
                Spacer()
                Button {
                    waveformEnabled.toggle()
                } label: {
                    Image(systemName: "waveform")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .foregroundStyle(waveformEnabled ? Color.accentColor : Color.secondary)
                .help(waveformEnabled ? "Switch to slider seek" : "Switch to waveform seek")
                Button {
                    main.outputChannel = isStereo ? .left : .both
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
                    TrackInfoView(
                        track: track,
                        artworkSize: artworkSize,
                        titleFont: titleFont,
                        showsBPM: isPerformance
                    )
                    Spacer()
                    if isPerformance {
                        performanceNextTrackSection(track: performanceNextTrack, fixedWidth: upNextPanelWidth)
                    }
                }
            } else {
                HStack {
                    Text("No track loaded")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isPerformance {
                        performanceNextTrackSection(track: performanceNextTrack, fixedWidth: upNextPanelWidth)
                    }
                }
            }

            // Seek bar
            HStack(spacing: 6) {
                Text(main.currentTime.mmss())
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)

                if waveformEnabled {
                    WaveformSeekBar(
                        waveformData: main.waveformData,
                        currentTime: main.currentTime,
                        duration: max(main.duration, 0.01),
                        onBeginSeek: { main.beginInteractiveSeek() },
                        onSeek: { main.seek(to: $0) },
                        onEndSeek: { main.endInteractiveSeek() }
                    )
                } else {
                    Slider(
                        value: Binding(
                            get: { main.currentTime },
                            set: { main.seek(to: $0) }
                        ),
                        in: 0...max(main.duration, 0.01),
                        onEditingChanged: { editing in
                            if editing { main.beginInteractiveSeek() }
                            else { main.endInteractiveSeek() }
                        }
                    )
                    .focusable(false)
                }

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

    @ViewBuilder
    private func performanceNextTrackSection(track: Track?, fixedWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Up Next")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if let track {
                HStack(spacing: 12) {
                    TrackInfoView(track: track, artworkSize: 42, titleFont: .headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formattedBPM(track.bpm))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(track.duration.mmss())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } else {
                Text("No next track queued")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: fixedWidth, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formattedBPM(_ bpm: Double?) -> String {
        guard let bpm else { return "BPM --" }
        return "\(Int(bpm.rounded())) BPM"
    }

    private var performanceNextTrack: Track? {
        let main = appState.mainPlayback
        guard !main.playlist.isEmpty else { return nil }
        if main.currentTrack == nil {
            return main.playlist.first
        }
        let nextIndex = main.currentTrackIndex + 1
        guard nextIndex >= 0, nextIndex < main.playlist.count else { return nil }
        return main.playlist[nextIndex]
    }

    // MARK: - Preview/Cue Section

    private var previewSection: some View {
        let preview = appState.previewPlayback
        let isStereo = preview.outputChannel == .both

        return VStack(spacing: 8) {
            HStack {
                Label(isStereo ? "Preview/Cue (L+R)" : "Preview/Cue (R)",
                      systemImage: "headphones")
                    .font(.headline)
                Spacer()
                Button {
                    preview.outputChannel = isStereo ? .right : .both
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
                    TrackInfoView(track: track, artworkSize: 52, titleFont: .title3, showsBPM: true)
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

                if waveformEnabled {
                    WaveformSeekBar(
                        waveformData: preview.waveformData,
                        currentTime: preview.currentTime,
                        duration: max(preview.duration, 0.01),
                        onBeginSeek: { preview.beginInteractiveSeek() },
                        onSeek: { preview.seek(to: $0) },
                        onEndSeek: { preview.endInteractiveSeek() }
                    )
                } else {
                    Slider(
                        value: Binding(
                            get: { preview.currentTime },
                            set: { preview.seek(to: $0) }
                        ),
                        in: 0...max(preview.duration, 0.01),
                        onEditingChanged: { editing in
                            if editing { preview.beginInteractiveSeek() }
                            else { preview.endInteractiveSeek() }
                        }
                    )
                    .focusable(false)
                }

                Text(preview.duration.mmss())
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
            }

            // Transport controls centered, volume stays right-aligned.
            ZStack {
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
                }

                HStack {
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

}

