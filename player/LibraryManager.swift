//
//  LibraryManager.swift
//  player
//

import Accelerate
import AppKit
import AVFoundation
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum LibraryError: LocalizedError {
    case fileNotFound(URL)
    case unsupportedFormat(String)
    case duplicateTrack(String)
    case metadataLoadFailed(URL, Error)
    case noLibraryFolder

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .unsupportedFormat(let ext):
            return "Unsupported audio format: \(ext)"
        case .duplicateTrack(let name):
            return "Track already in library: \(name)"
        case .metadataLoadFailed(let url, let error):
            return "Failed to load metadata for \(url.lastPathComponent): \(error.localizedDescription)"
        case .noLibraryFolder:
            return "No library folder is open."
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

    /// Set by AppState when a library folder is opened. All file operations are relative to this.
    var libraryFolderURL: URL?

    // MARK: - Public API

    /// Imports audio files into the library.
    /// Each file is **copied** into the library's Music/ subfolder before being tracked.
    /// Skips duplicates and returns only newly imported tracks.
    @discardableResult
    func importFiles(urls: [URL], modelContext: ModelContext) async throws -> [Track] {
        guard let libraryFolderURL else { throw LibraryError.noLibraryFolder }

        var importedTracks: [Track] = []
        for url in urls {
            do {
                if let track = try await importFile(url, libraryFolderURL: libraryFolderURL, modelContext: modelContext) {
                    importedTracks.append(track)
                }
            } catch {
                print("⚠️ Failed to import \(url.lastPathComponent): \(error)")
                continue
            }
        }
        return importedTracks
    }

    private func importFile(_ sourceURL: URL, libraryFolderURL: URL, modelContext: ModelContext) async throws -> Track? {
        // Gain access to the source file (e.g. from file picker)
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        // Validate file exists
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LibraryError.fileNotFound(sourceURL)
        }

        // Validate supported format
        let ext = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw LibraryError.unsupportedFormat(ext)
        }

        // Determine destination path in library's Music folder
        let musicFolder = libraryFolderURL.appending(path: "Music")
        let destURL = uniqueDestinationURL(in: musicFolder, for: sourceURL)
        let relativePath = "Music/\(destURL.lastPathComponent)"

        // Check for duplicates by relative path
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate<Track> { $0.relativePath == relativePath }
        )
        let existingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        if existingCount > 0 {
            return nil
        }

        // Copy the file into the library's Music folder
        try FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        // Extract metadata from the copied file (no bookmark needed — folder access is active)
        let metadata = await extractMetadata(from: destURL)

        var bpm = metadata.bpm
        if bpm == nil {
            bpm = await detectBPM(url: destURL)
        }

        let track = Track(
            relativePath: relativePath,
            fileURL: destURL,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            duration: metadata.duration,
            bpm: bpm
        )
        track.artworkData = metadata.artworkData

        modelContext.insert(track)
        return track
    }

    /// Returns a URL in `folder` that doesn't conflict with existing files.
    /// Appends " (2)", " (3)", … to the base name if needed.
    private func uniqueDestinationURL(in folder: URL, for sourceURL: URL) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var candidate = folder.appending(path: sourceURL.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Re-extracts metadata and artwork from the file for the given tracks.
    /// Preserves user-edited fields: rating, play count, last played date, cue points.
    func refreshMetadata(for tracks: [Track], modelContext: ModelContext) async {
        for track in tracks {
            let url = track.accessibleURL(libraryFolderURL: libraryFolderURL)

            guard FileManager.default.fileExists(atPath: url.path) else {
                print("⚠️ File not found during refresh: \(url.lastPathComponent)")
                continue
            }

            let metadata = await extractMetadata(from: url)
            track.title = metadata.title
            track.artist = metadata.artist
            track.album = metadata.album
            track.duration = metadata.duration
            if let bpm = metadata.bpm { track.bpm = bpm }
            if let artwork = metadata.artworkData { track.artworkData = artwork }
        }
    }

    /// Deletes a track from the library: moves its audio file to the Trash, then removes the record.
    func deleteTrack(_ track: Track, modelContext: ModelContext) {
        // Move the audio file to Trash if it's inside the library folder
        if !track.relativePath.isEmpty, let folderURL = libraryFolderURL {
            let fileURL = folderURL.appending(path: track.relativePath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            }
        }

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
        var duration: TimeInterval
        var bpm: Double?
        var artworkData: Data?
    }

    private func extractMetadata(from url: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: url)

        let duration: TimeInterval = (try? await asset.load(.duration).seconds) ?? 0
        let metadataItems: [AVMetadataItem] = (try? await asset.load(.commonMetadata)) ?? []

        let title = await metadataValue(for: .commonIdentifierTitle, in: metadataItems)
            ?? url.deletingPathExtension().lastPathComponent
        let artist = await metadataValue(for: .commonIdentifierArtist, in: metadataItems) ?? ""
        let album = await metadataValue(for: .commonIdentifierAlbumName, in: metadataItems) ?? ""

        var bpm: Double?
        if let id3Items = try? await asset.loadMetadata(for: .id3Metadata) {
            if let bpmString = await metadataValue(for: .id3MetadataBeatsPerMinute, in: id3Items) {
                bpm = Double(bpmString)
            }
        }
        if bpm == nil, let iTunesItems = try? await asset.loadMetadata(for: .iTunesMetadata) {
            if let bpmString = await metadataValue(for: .iTunesMetadataBeatsPerMin, in: iTunesItems) {
                bpm = Double(bpmString)
            }
        }
        if bpm == 0 { bpm = nil }

        let artworkData = await extractArtwork(from: metadataItems)

        return TrackMetadata(
            title: title,
            artist: artist,
            album: album,
            duration: duration.isNaN ? 0 : duration,
            bpm: bpm,
            artworkData: artworkData
        )
    }

    private func extractArtwork(from items: [AVMetadataItem]) async -> Data? {
        let artworkItems = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork)
        guard let item = artworkItems.first,
              let data = try? await item.load(.dataValue),
              let image = NSImage(data: data) else {
            return nil
        }
        return thumbnailData(from: image, maxSize: 200)
    }

    private func thumbnailData(from image: NSImage, maxSize: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxSize / size.width, maxSize / size.height, 1.0)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1.0)
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return nil
        }
        return jpeg
    }

    // MARK: - BPM Detection

    /// Estimates the BPM of an audio file using energy-envelope autocorrelation.
    func detectBPM(url: URL) async -> Double? {
        await Task.detached(priority: .utility) {
            Self.computeBPM(url: url)
        }.value
    }

    private nonisolated static func computeBPM(url: URL) -> Double? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }

        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)

        let maxFrames = AVAudioFrameCount(min(audioFile.length, Int64(sampleRate * 60)))
        guard maxFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames),
              (try? audioFile.read(into: buffer, frameCount: maxFrames)) != nil,
              let floatData = buffer.floatChannelData else { return nil }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        for ch in 0..<channels {
            vDSP_vadd(mono, 1, floatData[ch], 1, &mono, 1, vDSP_Length(frameCount))
        }
        var normFactor = Float(1.0 / Double(channels))
        vDSP_vsmul(mono, 1, &normFactor, &mono, 1, vDSP_Length(frameCount))

        let windowSize = 1024
        let hopSize = 512
        let numWindows = (frameCount - windowSize) / hopSize
        guard numWindows > 20 else { return nil }

        var energy = [Float](repeating: 0, count: numWindows)
        for w in 0..<numWindows {
            var rms: Float = 0
            vDSP_rmsqv(mono.withUnsafeBufferPointer { $0.baseAddress! + w * hopSize },
                       1, &rms, vDSP_Length(windowSize))
            energy[w] = rms
        }

        var onset = [Float](repeating: 0, count: numWindows)
        for i in 1..<numWindows {
            onset[i] = max(0, energy[i] - energy[i - 1])
        }

        let hopDuration = Double(hopSize) / sampleRate
        let minLag = max(1, Int(0.25 / hopDuration))
        let maxLag = Int(1.2 / hopDuration)
        guard maxLag < numWindows else { return nil }

        var bestLag = 0
        var bestCorr: Float = 0

        onset.withUnsafeBufferPointer { ptr in
            for lag in minLag...maxLag {
                var corr: Float = 0
                let count = numWindows - lag
                vDSP_dotpr(ptr.baseAddress!, 1,
                           ptr.baseAddress! + lag, 1,
                           &corr, vDSP_Length(count))
                corr /= Float(count)
                if corr > bestCorr {
                    bestCorr = corr
                    bestLag = lag
                }
            }
        }

        guard bestLag > 0 else { return nil }

        var bpm = 60.0 / (Double(bestLag) * hopDuration)
        while bpm < 50  { bpm *= 2 }
        while bpm > 275 { bpm /= 2 }

        return round(bpm)
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
