import AppKit
import AVFoundation
import SwiftUI

// Shared utilities used across the app.

// MARK: - Window Frame Autosave

/// Bridges AppKit's frame autosave to SwiftUI windows.
/// The window frame key should be stable and unique per logical window.
struct WindowAutosaver: NSViewRepresentable {
    let name: String

    func makeCoordinator() -> Coordinator {
        Coordinator(name: name)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.name = name
        if let window = nsView.window {
            context.coordinator.configure(window: window)
        }
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            coordinator?.configure(window: window)
        }

        override func viewWillDraw() {
            super.viewWillDraw()
            guard let window else { return }
            coordinator?.applyInitialFrameIfNeeded(window: window)
        }
    }

    final class Coordinator {
        var name: String
        private weak var configuredWindow: NSWindow?
        private var configuredName: String?
        private var observers: [NSObjectProtocol] = []
        private var hasAppliedInitialFrame = false
        private var isReadyToPersist = false
        private var initialDescriptor: String?

        init(name: String) {
            self.name = name
        }

        func configure(window: NSWindow) {
            guard configuredWindow !== window || configuredName != name else { return }
            detachObservers()
            configuredWindow = window
            configuredName = name
            hasAppliedInitialFrame = false
            isReadyToPersist = false

            let defaults = UserDefaults.standard
            let appKitKey = "NSWindow Frame \(name)"
            if let raw = defaults.string(forKey: appKitKey), raw.hasPrefix("{{") {
                defaults.removeObject(forKey: appKitKey)
            }

            let autosaveSet = window.setFrameAutosaveName(name)
            let stored = defaults.string(forKey: appKitKey)
            initialDescriptor = stored

            let save: (Notification) -> Void = { [weak window] _ in
                guard let window else { return }
                guard self.isReadyToPersist else {
                    return
                }
                self.persistFrame(window: window)
            }

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: save))
            observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: save))
            observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: save))

        }

        private func detachObservers() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }

        private func persistFrame(window: NSWindow) {
            window.saveFrame(usingName: name)
            let appKitKey = "NSWindow Frame \(name)"
            let serialized = window.frameDescriptor
            UserDefaults.standard.set(serialized, forKey: appKitKey)
        }

        func applyInitialFrameIfNeeded(window: NSWindow) {
            guard !hasAppliedInitialFrame else { return }
            hasAppliedInitialFrame = true

            var restored = false
            if let descriptor = initialDescriptor, !descriptor.hasPrefix("{{") {
                window.setFrame(from: descriptor)
                restored = true
            } else {
                restored = window.setFrameUsingName(name, force: false)
                if !restored {
                    let appKitKey = "NSWindow Frame \(name)"
                    if let persisted = UserDefaults.standard.string(forKey: appKitKey), !persisted.hasPrefix("{{") {
                        window.setFrame(from: persisted)
                        restored = true
                    }
                }
            }

            isReadyToPersist = true
        }

        deinit {
            detachObservers()
        }
    }
}

// MARK: - Clamping

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Time Formatting

extension TimeInterval {
    /// Returns a "m:ss" string, e.g. "3:07". Returns "0:00" for non-finite or negative values.
    func mmss() -> String {
        guard isFinite && self >= 0 else { return "0:00" }
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
