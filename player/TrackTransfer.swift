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
}
