//
//  TrackTransfer.swift
//  player
//

import Foundation

/// Encodes/decodes track UUID strings for drag-and-drop between library and playlists.
enum TrackTransfer {
    private static let separator = "\n"

    static func encode(trackIDs: [UUID]) -> String {
        trackIDs.map(\.uuidString).joined(separator: separator)
    }

    static func decode(_ string: String) -> [UUID] {
        string.split(separator: separator).compactMap { UUID(uuidString: String($0)) }
    }

    static func decode(_ strings: [String]) -> [UUID] {
        strings.flatMap { decode($0) }
    }

    static func tracks(from strings: [String], in candidates: [Track]) -> [Track] {
        let ids = Set(decode(strings))
        return candidates.filter { ids.contains($0.id) }
    }
}
