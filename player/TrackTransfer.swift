//
//  TrackTransfer.swift
//  player
//

import Foundation

/// Encodes/decodes track UUID strings for drag-and-drop between library and playlists.
enum TrackTransfer {
    private static let separator = "\n"

    enum Origin: Equatable {
        case library
        case playlist(UUID)
    }

    /// Where the in-flight drag started. Set when a drag begins; drop targets
    /// use it to decide between moving and copying.
    static var dragOrigin: Origin?

    /// Records the drag origin and returns the encoded payload. Use as the
    /// `.draggable` payload — SwiftUI evaluates it lazily when the drag starts.
    static func beginDrag(trackIDs: [UUID], from playlistID: UUID?) -> String {
        dragOrigin = playlistID.map { .playlist($0) } ?? .library
        return encode(trackIDs: trackIDs)
    }

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

    /// Loads the string payloads from dropped item providers, calling
    /// `completion` once on the main queue with all of them.
    static func loadStrings(from providers: [NSItemProvider], completion: @escaping ([String]) -> Void) {
        let group = DispatchGroup()
        var strings: [String] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                DispatchQueue.main.async {
                    if let string = item as? String { strings.append(string) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(strings) }
    }
}
