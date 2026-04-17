import AVFoundation

// Shared utilities used across the app.

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
