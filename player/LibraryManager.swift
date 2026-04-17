//
//  LibraryManager.swift
//  player
//

import AVFoundation
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum LibraryError: LocalizedError {
    case fileNotFound(URL)
    case unsupportedFormat(String)
    case duplicateTrack(URL)
    case metadataLoadFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .unsupportedFormat(let ext):
            return "Unsupported audio format: \(ext)"
        case .duplicateTrack(let url):
            return "Track already in library: \(url.lastPathComponent)"
        case .metadataLoadFailed(let url, let error):
            return "Failed to load metadata for \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

@Observable
final class LibraryManager {

    static let supportedTypes: [UTType] = [
        .mp3,
        .aiff,
        .wav,
        .mpeg4Audio,       // .m4a
        UTType("public.aac-audio") ?? .audio,
        UTType("org.xiph.flac") ?? .audio,
    ]

    private static let supportedExtensions: Set<String> = [
        "mp3", "aac", "wav", "aiff", "aif", "m4a", "flac"
    ]

    // MARK: - Public API

    /// Imports audio files into the library, extracting metadata from each.
    /// Skips duplicates (files whose URL already exists in the library) and returns only newly imported tracks.
    /// Throws on the first hard error (file not found, unsupported format).
    @discardableResult
    func importFiles(urls: [URL], modelContext: ModelContext) async throws -> [Track] {
        var importedTracks: [Track] = []

        for url in urls {
            // Gain access to security-scoped resources (e.g. from file picker)
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            // Validate file exists
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LibraryError.fileNotFound(url)
            }

            // Validate supported format
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else {
                throw LibraryError.unsupportedFormat(ext)
            }

            // Check for duplicates
            let fileURL = url.standardizedFileURL
            let descriptor = FetchDescriptor<Track>(
                predicate: #Predicate<Track> { track in
                    track.fileURL == fileURL
                }
            )
            let existingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
            if existingCount > 0 {
                // Skip duplicates silently rather than failing the whole import
                continue
            }

            // Extract metadata
            let metadata = await extractMetadata(from: url)

            let track = Track(
                fileURL: fileURL,
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                genre: metadata.genre,
                duration: metadata.duration
            )

            modelContext.insert(track)
            importedTracks.append(track)
        }

        return importedTracks
    }

    /// Deletes a track from the library and removes all associated playlist entries.
    func deleteTrack(_ track: Track, modelContext: ModelContext) {
        // PlaylistEntry has a relationship to Track; remove entries first
        for entry in track.playlistEntries {
            modelContext.delete(entry)
        }
        modelContext.delete(track)
    }

    // MARK: - Metadata Extraction

    private struct TrackMetadata {
        var title: String
        var artist: String
        var album: String
        var genre: String
        var duration: TimeInterval
    }

    private func extractMetadata(from url: URL) async -> TrackMetadata {
        let asset = AVAsset(url: url)

        // Load duration
        let duration: TimeInterval = (try? await asset.load(.duration).seconds) ?? 0

        // Load common metadata
        let metadataItems: [AVMetadataItem] = (try? await asset.load(.commonMetadata)) ?? []

        let title = await metadataValue(for: .commonIdentifierTitle, in: metadataItems)
            ?? url.deletingPathExtension().lastPathComponent
        let artist = await metadataValue(for: .commonIdentifierArtist, in: metadataItems) ?? ""
        let album = await metadataValue(for: .commonIdentifierAlbumName, in: metadataItems) ?? ""

        // Genre may be in common metadata or ID3/iTunes metadata
        var genre = await metadataValue(for: .commonIdentifierType, in: metadataItems) ?? ""
        if genre.isEmpty {
            // Try loading format-specific metadata for genre
            if let id3Items = try? await asset.loadMetadata(for: .id3Metadata) {
                genre = await metadataValue(for: .id3MetadataContentType, in: id3Items) ?? ""
            }
            if genre.isEmpty, let iTunesItems = try? await asset.loadMetadata(for: .iTunesMetadata) {
                genre = await metadataValue(for: .iTunesMetadataUserGenre, in: iTunesItems) ?? ""
            }
        }

        return TrackMetadata(
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            duration: duration.isNaN ? 0 : duration
        )
    }

    private func metadataValue(
        for identifier: AVMetadataIdentifier,
        in items: [AVMetadataItem]
    ) async -> String? {
        let filtered = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        guard let item = filtered.first else { return nil }
        let value = try? await item.load(.stringValue)
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
