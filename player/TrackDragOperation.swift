//
//  TrackDragOperation.swift
//  player
//

import AppKit
import ObjectiveC
import SwiftUI
import UniformTypeIdentifiers

/// Move-vs-copy rules for track drags, following the Finder convention:
/// dragging between playlists moves, holding Option copies (the cursor shows
/// a "+" badge). Drags from the library always copy. The Option key can be
/// pressed or released at any point; the state at drop time decides.
enum TrackDragOperation {

    /// The playlist dropped tracks should be removed from if the drop happened
    /// now — the origin playlist for a move, nil for a copy.
    static var moveSourcePlaylistID: UUID? {
        guard case .playlist(let id) = TrackTransfer.dragOrigin,
              !NSEvent.modifierFlags.contains(.option) else { return nil }
        return id
    }

    static var isMove: Bool { moveSourcePlaylistID != nil }

    /// Captures the move source at drop time and ends the drag.
    static func takeMoveSource() -> UUID? {
        let id = moveSourcePlaylistID
        TrackTransfer.dragOrigin = nil
        return id
    }

    // MARK: - List Insert Badge

    /// `List.onInsert` has no way to specify the drop operation, so the cursor
    /// badge can't reflect move vs copy. This wraps the drag-over methods of
    /// SwiftUI's List view (an NSOutlineView subclass) to report the operation
    /// the drop will perform. Drags within the same list (reorders via
    /// `onMove`) and drags that aren't in-app track drags keep SwiftUI's
    /// operation. If SwiftUI's internals change and the class is missing,
    /// this is a no-op.
    static func installListDropBadge() {
        _ = installOnce
    }

    private static let installOnce: Void = {
        // Hooked at the view rather than the list's data source: the data
        // source is a generic class with a distinct runtime class per
        // selection type, while the view class is fixed.
        guard let listClass = NSClassFromString("SwiftUI.SwiftUIOutlineListView") else { return }

        for selector in [#selector(NSView.draggingEntered(_:)), #selector(NSView.draggingUpdated(_:))] {
            guard let method = class_getInstanceMethod(listClass, selector),
                  let originalIMP = class_getMethodImplementation(listClass, selector)
            else { continue }

            typealias DragOver = @convention(c) (NSView, Selector, NSDraggingInfo) -> NSDragOperation
            let original = unsafeBitCast(originalIMP, to: DragOver.self)

            let replacement: @convention(block) (NSView, NSDraggingInfo) -> NSDragOperation = { view, info in
                let operation = original(view, selector, info)
                guard !operation.isEmpty,
                      TrackTransfer.dragOrigin != nil,
                      let source = info.draggingSource as? NSTableView,
                      source !== view
                else { return operation }
                return isMove ? .move : .copy
            }
            let imp = imp_implementationWithBlock(replacement)
            // The methods are normally inherited from NSOutlineView; add an
            // override on the subclass only, so other table views are untouched.
            if !class_addMethod(listClass, selector, imp, method_getTypeEncoding(method)) {
                method_setImplementation(method, imp)
            }
        }
    }()
}

/// Drop target for track drags that shows the move/copy cursor badge and
/// hands the dropped payload plus the move source to `perform`.
struct TrackDropDelegate: DropDelegate {
    var isTargeted: Binding<Bool>? = nil
    /// Called with the dropped payload strings and, for a move, the playlist
    /// the tracks came from.
    let perform: (_ strings: [String], _ moveSourcePlaylistID: UUID?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        isTargeted?.wrappedValue = true
    }

    func dropExited(info: DropInfo) {
        isTargeted?.wrappedValue = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: TrackDragOperation.isMove ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted?.wrappedValue = false
        let providers = info.itemProviders(for: [.utf8PlainText])
        guard !providers.isEmpty else { return false }
        let moveSource = TrackDragOperation.takeMoveSource()
        TrackTransfer.loadStrings(from: providers) { strings in
            perform(strings, moveSource)
        }
        return true
    }
}
