//
//  PlaylistIO.swift
//  player
//

import AppKit
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Exported Data Structures

struct PlaylistExportData: Codable {
    var version: Int = 1
    var name: String
    var dateExported: Date
    var summary: PlaylistSummaryData
    var tracks: [PlaylistTrackData]
}

struct PlaylistSummaryData: Codable {
    var trackCount: Int
    var totalDuration: TimeInterval
    var bpmMin: Double?
    var bpmMax: Double?
    var bpmAverage: Double?
    var averageRating: Double?
    var unplayedCount: Int
}

struct PlaylistTrackData: Codable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var bpm: Double?
    var rating: Int
    var tags: [String]
    var cuePointIn: TimeInterval?
    var cuePointOut: TimeInterval?
    var relativePath: String
}

// MARK: - FocusedValues

extension FocusedValues {
    @Entry var focusedPlaylist: Playlist? = nil
    @Entry var playlistImportHandler: ((PlaylistExportData) -> Void)? = nil
}

// MARK: - PlaylistIO

enum PlaylistIO {

    static func makeExportData(for playlist: Playlist) -> PlaylistExportData {
        let tracks = playlist.orderedTracks
        let bpms = tracks.compactMap(\.bpm).filter { $0 > 0 }
        let ratings = tracks.map(\.rating).filter { $0 > 0 }

        let summary = PlaylistSummaryData(
            trackCount: tracks.count,
            totalDuration: tracks.reduce(0) { $0 + $1.duration },
            bpmMin: bpms.min(),
            bpmMax: bpms.max(),
            bpmAverage: bpms.isEmpty ? nil : bpms.reduce(0, +) / Double(bpms.count),
            averageRating: ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count),
            unplayedCount: tracks.filter { $0.playCount == 0 }.count
        )

        return PlaylistExportData(
            name: playlist.name,
            dateExported: Date(),
            summary: summary,
            tracks: tracks.map { track in
                PlaylistTrackData(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: track.duration,
                    bpm: track.bpm,
                    rating: track.rating,
                    tags: track.tags,
                    cuePointIn: track.cuePointIn,
                    cuePointOut: track.cuePointOut,
                    relativePath: track.relativePath
                )
            }
        )
    }

    static func encode(_ data: PlaylistExportData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(data)
    }

    static func decode(from data: Data) throws -> PlaylistExportData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlaylistExportData.self, from: data)
    }

    /// Creates a new playlist from exported data, matching tracks by relativePath then title+artist.
    /// Returns the new playlist and the number of tracks that could not be matched.
    @discardableResult
    static func importPlaylist(
        from exportData: PlaylistExportData,
        libraryTracks: [Track],
        modelContext: ModelContext,
        playlistManager: PlaylistManager
    ) -> (playlist: Playlist, unmatchedCount: Int) {
        let playlist = playlistManager.createPlaylist(name: exportData.name, modelContext: modelContext)

        var unmatchedCount = 0
        for trackData in exportData.tracks {
            if let match = libraryTracks.first(where: {
                !$0.relativePath.isEmpty && $0.relativePath == trackData.relativePath
            }) {
                playlistManager.addTrack(match, to: playlist, modelContext: modelContext)
            } else if let match = libraryTracks.first(where: {
                $0.title.lowercased() == trackData.title.lowercased() &&
                $0.artist.lowercased() == trackData.artist.lowercased()
            }) {
                playlistManager.addTrack(match, to: playlist, modelContext: modelContext)
            } else {
                unmatchedCount += 1
            }
        }

        return (playlist, unmatchedCount)
    }
}

// MARK: - PlaylistCommands

struct PlaylistCommands: Commands {
    @FocusedValue(\.focusedPlaylist) private var focusedPlaylist: Playlist?
    @FocusedValue(\.playlistImportHandler) private var importHandler: ((PlaylistExportData) -> Void)?

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Playlist…") {
                guard let playlist = focusedPlaylist else { return }
                exportPlaylist(playlist)
            }
            .disabled(focusedPlaylist == nil)

            Button("Import Playlist…") {
                guard let handler = importHandler else { return }
                importPlaylist(using: handler)
            }
            .disabled(importHandler == nil)
        }
    }

    private func exportPlaylist(_ playlist: Playlist) {
        guard let data = try? PlaylistIO.encode(PlaylistIO.makeExportData(for: playlist)) else { return }

        let panel = NSSavePanel()
        panel.title = "Export Playlist"
        panel.nameFieldStringValue = "\(playlist.name).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func importPlaylist(using handler: (PlaylistExportData) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Import Playlist"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let exportData = try PlaylistIO.decode(from: data)
            handler(exportData)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Import Playlist"
            alert.informativeText = "The file doesn't appear to be a valid playlist export."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
