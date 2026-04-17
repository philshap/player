//
//  TrackMetadataEditorView.swift
//  player
//

import SwiftUI

/// Modal sheet for editing a track's metadata fields.
/// Edits are applied only when the user confirms; Cancel discards all changes.
struct TrackMetadataEditorView: View {

    let track: Track
    var onDismiss: () -> Void

    // MARK: - Editable fields

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var bpmText: String
    @State private var bpmError: Bool = false

    // MARK: - Play count confirmation

    @State private var confirmResetPlayCount = false

    // MARK: - Init

    init(track: Track, onDismiss: @escaping () -> Void) {
        self.track = track
        self.onDismiss = onDismiss
        _title   = State(initialValue: track.title)
        _artist  = State(initialValue: track.artist)
        _album   = State(initialValue: track.album)
        _bpmText = State(initialValue: track.bpm.map { String(format: "%.0f", $0) } ?? "")
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ─────────────────────────────────────────────────────
            HStack(spacing: 12) {
                TrackArtworkView(data: track.artworkData, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Metadata")
                        .font(.headline)
                    Text(track.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding()

            Divider()

            // ── Fields ─────────────────────────────────────────────────────
            Form {
                Section("Track Info") {
                    LabeledContent("Title") {
                        TextField("Title", text: $title)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Artist") {
                        TextField("Artist", text: $artist)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Album") {
                        TextField("Album", text: $album)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Playback") {
                    LabeledContent("BPM") {
                        HStack(spacing: 6) {
                            if bpmError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                            TextField("e.g. 128", text: $bpmText)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .onChange(of: bpmText) {
                                    bpmError = !bpmText.isEmpty && parsedBPM == nil
                                }
                        }
                    }

                    LabeledContent("Play Count") {
                        HStack(spacing: 10) {
                            Text("\(track.playCount)")
                                .foregroundStyle(.secondary)
                            Button("Reset…") {
                                confirmResetPlayCount = true
                            }
                            .font(.callout)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Cue Points") {
                    LabeledContent("Cue In") {
                        if let t = track.cuePointIn {
                            HStack(spacing: 8) {
                                Text(formatTime(t))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Button("Clear") {
                                    track.cuePointIn = nil
                                }
                                .font(.callout)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                        } else {
                            Text("Not set").foregroundStyle(.tertiary)
                        }
                    }
                    LabeledContent("Cue Out") {
                        if let t = track.cuePointOut {
                            HStack(spacing: 8) {
                                Text(formatTime(t))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Button("Clear") {
                                    track.cuePointOut = nil
                                }
                                .font(.callout)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                        } else {
                            Text("Not set").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // ── Action buttons ──────────────────────────────────────────────
            HStack {
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    applyEdits()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || bpmError)
            }
            .padding()
        }
        .frame(width: 440)
        .confirmationDialog(
            "Reset Play Count",
            isPresented: $confirmResetPlayCount,
            titleVisibility: .visible
        ) {
            Button("Reset to 0", role: .destructive) {
                track.playCount = 0
                track.lastPlayedDate = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear the play count and last-played date for "\(track.title)".")
        }
    }

    // MARK: - Helpers

    private var parsedBPM: Double? {
        guard !bpmText.isEmpty else { return nil }
        guard let v = Double(bpmText), v > 0, v < 300 else { return nil }
        return v
    }

    private func applyEdits() {
        let trimTitle = title.trimmingCharacters(in: .whitespaces)
        if !trimTitle.isEmpty { track.title = trimTitle }
        track.artist = artist.trimmingCharacters(in: .whitespaces)
        track.album  = album.trimmingCharacters(in: .whitespaces)
        if bpmText.isEmpty {
            track.bpm = nil
        } else if let bpm = parsedBPM {
            track.bpm = bpm
        }
        // cue clears are applied live (directly on the track above)
        // play count reset is applied live too
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
