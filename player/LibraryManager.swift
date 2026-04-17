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
            do {
                if let track = try await importFile(url, modelContext) {
                    importedTracks.append(track)
                }
            } catch {
                print("⚠️ Failed to import \(url): \(error)")
                continue
            }
        }

        return importedTracks
    }
    
    private func importFile(_ url: URL, _ modelContext: ModelContext) async throws -> Track? {
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
            return nil
        }

        // Create security-scoped bookmark for persistent access
        let bookmark: Data?
        do {
            bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            print("[LibraryManager] Created bookmark (\(bookmark!.count) bytes) for: \(url.lastPathComponent)")
        } catch {
            print("[LibraryManager] Failed to create bookmark for \(url.lastPathComponent): \(error)")
            bookmark = nil
        }

        // Extract metadata
        let metadata = await extractMetadata(from: url)

        // Auto-detect BPM if not present in file tags
        var bpm = metadata.bpm
        if bpm == nil {
            bpm = await detectBPM(url: url)
        }

        let track = Track(
            fileURL: fileURL,
            bookmarkData: bookmark,
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

    /// Re-extracts metadata and artwork from the file for the given tracks.
    /// Preserves user-edited fields: rating, play count, last played date, cue points.
    func refreshMetadata(for tracks: [Track], modelContext: ModelContext) async {
        for track in tracks {
            // Resolve bookmark to get a security-scoped URL with access already started
            let url = track.accessibleURL()
            defer { url.stopAccessingSecurityScopedResource() }

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
        var duration: TimeInterval
        var bpm: Double?
        var artworkData: Data?
    }

    private func extractMetadata(from url: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: url)

        // Load duration
        let duration: TimeInterval = (try? await asset.load(.duration).seconds) ?? 0

        // Load common metadata
        let metadataItems: [AVMetadataItem] = (try? await asset.load(.commonMetadata)) ?? []

        let title = await metadataValue(for: .commonIdentifierTitle, in: metadataItems)
            ?? url.deletingPathExtension().lastPathComponent
        let artist = await metadataValue(for: .commonIdentifierArtist, in: metadataItems) ?? ""
        let album = await metadataValue(for: .commonIdentifierAlbumName, in: metadataItems) ?? ""

        // Extract BPM from ID3 or iTunes metadata
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

        // Extract artwork
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

    /// Resizes an image to fit within maxSize and returns JPEG data.
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
    /// Reads up to 60 seconds of audio and runs the computation on a utility thread.
    /// Returns nil if the file cannot be read or the tempo cannot be determined.
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

        // Read up to 60 s to keep this fast
        let maxFrames = AVAudioFrameCount(min(audioFile.length, Int64(sampleRate * 60)))
        guard maxFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames),
              (try? audioFile.read(into: buffer, frameCount: maxFrames)) != nil,
              let floatData = buffer.floatChannelData else { return nil }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        // Mix to mono using vDSP
        var mono = [Float](repeating: 0, count: frameCount)
        for ch in 0..<channels {
            vDSP_vadd(mono, 1, floatData[ch], 1, &mono, 1, vDSP_Length(frameCount))
        }
        var normFactor = Float(1.0 / Double(channels))
        vDSP_vsmul(mono, 1, &normFactor, &mono, 1, vDSP_Length(frameCount))

        // Compute RMS energy in overlapping windows
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

        // Half-wave rectified first difference (onset strength)
        var onset = [Float](repeating: 0, count: numWindows)
        for i in 1..<numWindows {
            onset[i] = max(0, energy[i] - energy[i - 1])
        }

        // Autocorrelation over the BPM-valid lag range
        let hopDuration = Double(hopSize) / sampleRate
        let minLag = max(1, Int(0.25 / hopDuration))  // ~240 BPM upper bound
        let maxLag = Int(1.2 / hopDuration)            // ~50  BPM lower bound
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

        // Fold into the common DJ BPM range (70–175)
        while bpm < 70  { bpm *= 2 }
        while bpm > 175 { bpm /= 2 }

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
