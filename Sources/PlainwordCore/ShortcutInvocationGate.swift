import Foundation

/// Collapses duplicate or accidental rapid shortcut invocations.
///
/// `NSEvent.timestamp` is monotonic for the lifetime of a boot, which makes it a
/// better input here than wall-clock time. A lower timestamp is treated as a new
/// clock sequence so the gate cannot remain closed across a reset.
public struct ShortcutInvocationGate: Sendable {
    private let minimumInterval: TimeInterval
    private var lastAcceptedTimestamp: TimeInterval?

    public init(minimumInterval: TimeInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    public mutating func accepts(timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite else { return false }
        guard let lastAcceptedTimestamp else {
            self.lastAcceptedTimestamp = timestamp
            return true
        }

        let elapsed = timestamp - lastAcceptedTimestamp
        if elapsed < 0 {
            self.lastAcceptedTimestamp = timestamp
            return true
        }
        guard elapsed >= minimumInterval else { return false }

        self.lastAcceptedTimestamp = timestamp
        return true
    }
}
