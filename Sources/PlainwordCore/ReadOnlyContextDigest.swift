import Foundation

/// A stable identity for the read-only context surrounding an edit target.
///
/// Context is harvested from a live screen under a wall-clock deadline, so two captures
/// of what a person would call the same situation routinely differ in whitespace, in
/// capitalisation, in an elision marker, or in the order geometry happened to put the
/// fragments in. Keying a cache on the exact fragments therefore misses far more often
/// than the context actually changed.
///
/// This folds away that noise while keeping the content that tells one conversation,
/// document, or form apart from another — a cache hit still has to mean the model would
/// have been handed materially the same context.
public enum ReadOnlyContextDigest {
    /// How much of a long value survives into the digest.
    ///
    /// Enough to distinguish two conversations, short enough that a passage growing at
    /// the end away from the target does not change its identity.
    public static let significantCharacters = 120

    /// Which end of an over-long value is kept.
    public enum Retention: Equatable, Sendable {
        /// Keep the start. Correct for context that follows the target, whose opening
        /// words are the ones adjacent to it.
        case start
        /// Keep the end. Correct for context that precedes the target, and for the
        /// fragments the ranker itself truncates from their far end.
        case end
    }

    public static func value(for fragments: [ReadOnlyContextFragment]) -> String {
        fragments.compactMap { fragment -> String? in
            let retention: Retention = fragment.kind.keepsNearestSuffixWhenTruncated
                ? .end
                : .start
            guard let folded = folded(fragment.text, retaining: retention) else {
                return nil
            }
            return "\(fragment.kind.rawValue)\(Self.unitSeparator)\(folded)"
        }
        // Fragments present in screen reading order, which shifts as the interface
        // scrolls. What identifies the context is the set, not the sequence.
        .sorted()
        .joined(separator: Self.recordSeparator)
    }

    public static func value(for text: String, retaining retention: Retention) -> String {
        folded(text, retaining: retention) ?? ""
    }

    private static let unitSeparator = "\u{1f}"
    private static let recordSeparator = "\u{1e}"

    /// Lowercases, drops everything that is not a letter or a number, and keeps the end
    /// of the value nearest the edit target.
    private static func folded(_ text: String, retaining retention: Retention) -> String? {
        let marker = ReadOnlyContextRanker.elisionMarker
        let stripped = text.hasPrefix(marker) ? String(text.dropFirst(marker.count)) : text
        let words = stripped.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return nil }

        let folded = words.joined(separator: " ")
        guard folded.count > significantCharacters else { return folded }
        return retention == .end
            ? String(folded.suffix(significantCharacters))
            : String(folded.prefix(significantCharacters))
    }
}
