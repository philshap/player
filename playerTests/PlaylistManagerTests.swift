//
//  PlaylistManagerTests.swift
//  playerTests
//
//  Tests for PlaylistManager track-ordering logic and the LibraryManager.deleteTrack
//  cleanup path. Uses XCTest so setUp() runs on the main thread, satisfying SwiftData's
//  thread-safety requirements without actor-isolation gymnastics. Each test gets a fresh
//  in-memory container, so no real application data is ever touched.
//

import XCTest
import SwiftData
@testable import player

@MainActor
final class PlaylistManagerTests: XCTestCase {

    // MARK: - Fixture

    private var container: ModelContainer!
    private var context:   ModelContext!
    private var manager:   PlaylistManager!
    private var playlist:  Playlist!
    private var a, b, c:   Track!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container  = try ModelContainer(for: Track.self, Playlist.self,
                                        configurations: config)
        context    = container.mainContext
        manager    = PlaylistManager()
        playlist   = Playlist(name: "Test")
        context.insert(playlist)
        a = track("A"); b = track("B"); c = track("C")
        manager.addTracks([a, b, c], to: playlist, modelContext: context)
    }

    override func tearDownWithError() throws {
        container = nil   // releases the in-memory store
    }

    private func track(_ title: String) -> Track {
        let t = Track(relativePath: "\(title).mp3",
                      fileURL: URL(fileURLWithPath: "/tmp/\(title).mp3"),
                      title: title)
        context.insert(t)
        return t
    }

    // MARK: - orderedTracks

    func test_orderedTracks_reflectsInsertionOrder() {
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["A", "B", "C"])
    }

    func test_orderedTracks_fallsBackToTracksWhenOrderIsEmpty() {
        // Simulate a playlist created before trackOrder was introduced.
        let legacy = Playlist(name: "Legacy")
        context.insert(legacy)
        legacy.tracks.append(contentsOf: [a, b])   // bypass PlaylistManager
        XCTAssert(legacy.trackOrder.isEmpty)
        XCTAssertEqual(legacy.orderedTracks.map(\.title), ["A", "B"])
    }

    // MARK: - insertTracks: regression cases

    // THE primary regression: dragging a track that already exists in the playlist
    // used to land at the wrong position when it came from before the drop target.
    func test_insertTracks_existingFromBefore_landsAfterTarget() {
        // [A,B,C] → drop A at index 2 (after B) → [B,A,C]
        manager.insertTracks([a], at: 2, into: playlist)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["B", "A", "C"])
    }

    func test_insertTracks_existingFromAfter_landsBeforeTarget() {
        // [A,B,C] → drop C at index 1 (before B) → [A,C,B]
        manager.insertTracks([c], at: 1, into: playlist)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["A", "C", "B"])
    }

    func test_insertTracks_existingAtSamePosition_noChange() {
        manager.insertTracks([a], at: 0, into: playlist)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["A", "B", "C"])
    }

    func test_insertTracks_existingToBeginning() {
        // [A,B,C] → drop C at index 0 → [C,A,B]
        manager.insertTracks([c], at: 0, into: playlist)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["C", "A", "B"])
    }

    func test_insertTracks_existingToEnd() {
        // [A,B,C] → drop A at index 3 → [B,C,A]
        manager.insertTracks([a], at: 3, into: playlist)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["B", "C", "A"])
    }

    // MARK: - insertTracks: new track

    func test_insertTracks_newTrack_insertsAtCorrectIndex() {
        // [A,B,C] → drop X at index 1 → [A,X,B,C]
        let x = track("X")
        manager.insertTracks([x], at: 1, into: playlist)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["A", "X", "B", "C"])
    }

    func test_insertTracks_newTrack_appearsInRelationship() {
        let x = track("X")
        manager.insertTracks([x], at: 0, into: playlist)
        XCTAssert(playlist.tracks.contains(where: { $0.id == x.id }))
    }

    // MARK: - addTrack

    func test_addTrack_duplicate_movesToEnd() {
        // [A,B,C] → addTrack A → [B,C,A]
        manager.addTrack(a, to: playlist, modelContext: context)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["B", "C", "A"])
    }

    func test_addTrack_new_appends() {
        let x = track("X")
        manager.addTrack(x, to: playlist, modelContext: context)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["A", "B", "C", "X"])
    }

    // MARK: - removeTrack

    func test_removeTrack_removesFromBothTracksAndTrackOrder() {
        manager.removeTrack(at: 1, from: playlist, modelContext: context)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["A", "C"])
        XCTAssertFalse(playlist.tracks.contains(where: { $0.id == b.id }))
        XCTAssertFalse(playlist.trackOrder.contains(b.id))
    }

    func test_removeTrack_indicesRemainValidAfterRemoval() {
        manager.removeTrack(at: 0, from: playlist, modelContext: context)
        // B is now at index 0
        manager.removeTrack(at: 0, from: playlist, modelContext: context)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["C"])
    }

    // MARK: - moveTrack

    func test_moveTrack_forward() {
        // [A,B,C] → move 0→2 → [B,C,A]
        manager.moveTrack(in: playlist, from: 0, to: 2)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["B", "C", "A"])
    }

    func test_moveTrack_backward() {
        // [A,B,C] → move 2→0 → [C,A,B]
        manager.moveTrack(in: playlist, from: 2, to: 0)
        XCTAssertEqual(playlist.orderedTracks.map(\.title), ["C", "A", "B"])
    }
}

// MARK: - LibraryManager.deleteTrack

final class LibraryDeleteTests: XCTestCase {

    func test_deleteTrack_removesUUIDFromAllContainingPlaylists() async throws {
        let config    = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self,
                                           configurations: config)

        await MainActor.run {
            let ctx     = container.mainContext
            let manager = PlaylistManager()

            let p1 = Playlist(name: "P1"); ctx.insert(p1)
            let p2 = Playlist(name: "P2"); ctx.insert(p2)

            func track(_ title: String) -> Track {
                let t = Track(relativePath: "\(title).mp3",
                              fileURL: URL(fileURLWithPath: "/tmp/\(title).mp3"),
                              title: title)
                ctx.insert(t); return t
            }
            let a = track("A"), b = track("B")

            manager.addTracks([a, b], to: p1, modelContext: ctx)
            manager.addTracks([b, a], to: p2, modelContext: ctx)

            LibraryManager().deleteTrack(a, modelContext: ctx)

            XCTAssertFalse(p1.trackOrder.contains(a.id))
            XCTAssertFalse(p2.trackOrder.contains(a.id))
            XCTAssertEqual(p1.trackOrder, [b.id])
            XCTAssertEqual(p2.trackOrder, [b.id])
        }
    }

    func test_deleteTrack_orphanedTrack_doesNotCrash() async throws {
        let config    = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self,
                                           configurations: config)

        await MainActor.run {
            let ctx = container.mainContext
            let x   = Track(relativePath: "x.mp3",
                            fileURL: URL(fileURLWithPath: "/tmp/x.mp3"),
                            title: "X")
            ctx.insert(x)
            LibraryManager().deleteTrack(x, modelContext: ctx)
        }
    }
}
