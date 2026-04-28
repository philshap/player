//
//  TrackMetadataEditorView.swift
//  player
//

import SwiftUI

/// Modal sheet for editing a track's metadata fields.
/// Accepts one or more tracks; when multiple tracks are provided, Prev/Next
/// buttons (and Command-P / Command-N) let the user traverse them.
/// Edits are applied to the current track when navigating or when Save is pressed;
/// Cancel on the last track discards only that track's unsaved changes.
struct TrackMetadataEditorView: View {

    let tracks: [Track]
    let allTags: [String]
    var onDismiss: () -> Void

    // MARK: - Editable fields

    @State private var currentIndex: Int
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var bpmText: String
    @State private var bpmError: Bool = false
    @State private var tags: [String]
    @State private var newTagInput: String = ""

    // MARK: - Play count confirmation

    @State private var confirmResetPlayCount = false

    @FocusState private var titleFocused: Bool

    // MARK: - Init

    init(tracks: [Track], startIndex: Int = 0, allTags: [String] = [], onDismiss: @escaping () -> Void) {
        precondition(!tracks.isEmpty)
        self.tracks = tracks
        self.allTags = allTags
        self.onDismiss = onDismiss
        let index = tracks.indices.contains(startIndex) ? startIndex : 0
        _currentIndex = State(initialValue: index)
        _title   = State(initialValue: tracks[index].title)
        _artist  = State(initialValue: tracks[index].artist)
        _album   = State(initialValue: tracks[index].album)
        _bpmText = State(initialValue: tracks[index].bpm.map { String(format: "%.0f", $0) } ?? "")
        _tags    = State(initialValue: tracks[index].tags)
    }

    // MARK: - Convenience

    private var track: Track { tracks[currentIndex] }
    private var isMultiple: Bool { tracks.count > 1 }

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
                if isMultiple {
                    HStack(spacing: 6) {
                        Button {
                            navigateTo(currentIndex - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .disabled(currentIndex == 0)
                        .keyboardShortcut(currentIndex > 0 ? KeyEquivalent("p") : KeyEquivalent("\0"), modifiers: .command)
                        .help("Previous track (⌘P)")

                        Text("\(currentIndex + 1) of \(tracks.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Button {
                            navigateTo(currentIndex + 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .disabled(currentIndex == tracks.count - 1)
                        .keyboardShortcut(currentIndex < tracks.count - 1 ? KeyEquivalent("n") : KeyEquivalent("\0"), modifiers: .command)
                        .help("Next track (⌘N)")
                    }
                }
            }
            .padding()

            Divider()

            // ── Fields ─────────────────────────────────────────────────────
            Form {
                Section("Track Info") {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .focused($titleFocused)
                    TextField("Artist", text: $artist)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                    TextField("Album", text: $album)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }

                Section("Tags") {
                    tagChipsRow
                    tagInputRow
                    tagSuggestionRows
                }

                Section("Playback") {
                    HStack(spacing: 6) {
                        if bpmError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                        TextField("BPM", text: $bpmText)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: bpmText) {
                                bpmError = !bpmText.isEmpty && parsedBPM == nil
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
                                Text(t.mmss())
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
                                Text(t.mmss())
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
        .onAppear { titleFocused = true }
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
            Text("This will clear the play count and last-played date for \"\(track.title)\".")
        }
    }

    // MARK: - Tag Section Views

    @ViewBuilder private var tagChipsRow: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        tagChip(tag)
                    }
                }
            }
            .frame(height: 30)
        }
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text(tag).font(.callout)
            Button {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5))
    }

    @ViewBuilder private var tagInputRow: some View {
        HStack {
            TextField("Add tag…", text: $newTagInput)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .onSubmit { commitNewTag() }
            if !newTagInput.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Add") { commitNewTag() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder private var tagSuggestionRows: some View {
        ForEach(tagSuggestions, id: \.self) { suggestion in
            Button {
                addTag(suggestion)
            } label: {
                HStack {
                    Image(systemName: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(suggestion)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Navigation

    private func navigateTo(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        applyEdits()
        currentIndex = index
        title       = track.title
        artist      = track.artist
        album       = track.album
        bpmText     = track.bpm.map { String(format: "%.0f", $0) } ?? ""
        tags        = track.tags
        newTagInput = ""
        bpmError    = false
        titleFocused = false
        Task { @MainActor in titleFocused = true }
    }

    // MARK: - Helpers

    private var parsedBPM: Double? {
        guard !bpmText.isEmpty else { return nil }
        guard let v = Double(bpmText), v > 0, v < 300 else { return nil }
        return v
    }

    private var tagSuggestions: [String] {
        let input = newTagInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return [] }
        return Array(allTags.filter { suggestion in
            !tags.contains(suggestion) &&
            suggestion.localizedCaseInsensitiveContains(input)
        }.prefix(5))
    }

    private func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        newTagInput = ""
    }

    private func commitNewTag() {
        addTag(newTagInput)
    }

    private func applyEdits() {
        let trimTitle = title.trimmingCharacters(in: .whitespaces)
        if !trimTitle.isEmpty { track.title = trimTitle }
        track.artist = artist.trimmingCharacters(in: .whitespaces)
        track.album  = album.trimmingCharacters(in: .whitespaces)
        track.tags   = tags
        if bpmText.isEmpty {
            track.bpm = nil
        } else if let bpm = parsedBPM {
            track.bpm = bpm
        }
        // cue clears and play count resets are applied live (directly on the track)
    }

}
