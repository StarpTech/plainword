import Foundation

/// The part of a target that a correction actually changed.
public struct NarrowedTextSpan: Equatable, Sendable {
    /// Where the changed part sits in the original target text.
    public let originalUTF16Range: NSRange
    /// What that part holds now, which the write is expected to be replacing.
    public let originalText: String
    /// What it should hold instead.
    public let replacement: String

    public init(
        originalUTF16Range: NSRange,
        originalText: String,
        replacement: String
    ) {
        self.originalUTF16Range = originalUTF16Range
        self.originalText = originalText
        self.replacement = replacement
    }
}

/// Reduces a correction to the span it actually changed, so a write can leave the rest
/// of the field alone.
///
/// A write through the accessibility API carries characters and nothing else. Whatever
/// the text it lands on was holding — the bold in a signature, a link, an inline image,
/// a font the author chose, the block structure of a paragraph — belongs to the editor,
/// and is rebuilt from the plain characters that arrive. Text that is written back
/// unchanged therefore does not survive unchanged: it survives as its own words in the
/// editor's default styling, which is how a correction to the second paragraph of an
/// email can strip the formatting from a signature nobody edited.
///
/// The way past it is to write less. A correction the model returned with the greeting
/// and the signature untouched is a correction to the middle, and only the middle needs
/// to be selected. Everything the two texts agree on at either end is left where it is,
/// still owned by the editor, with its formatting never in question.
///
/// Narrowing runs before any other write shaping, because it is what bounds the damage
/// when the rest cannot help: even a correction that merged two paragraphs, which cannot
/// be written line by line, still only reaches the paragraphs it merged.
public enum TextSpanNarrowing {
    /// Returns the span the correction changed, or `nil` when it changed nothing.
    ///
    /// Both ends are found by comparing characters rather than UTF-16 units, so a span
    /// never begins or ends inside an emoji, an accented letter, or any other character
    /// built from several units.
    public static func narrow(original: String, replacement: String) -> NarrowedTextSpan? {
        var originalStart = original.startIndex
        var replacementStart = replacement.startIndex
        while originalStart < original.endIndex,
              replacementStart < replacement.endIndex,
              original[originalStart] == replacement[replacementStart] {
            originalStart = original.index(after: originalStart)
            replacementStart = replacement.index(after: replacementStart)
        }

        var originalEnd = original.endIndex
        var replacementEnd = replacement.endIndex
        while originalEnd > originalStart, replacementEnd > replacementStart {
            let previousOriginal = original.index(before: originalEnd)
            let previousReplacement = replacement.index(before: replacementEnd)
            guard original[previousOriginal] == replacement[previousReplacement] else { break }
            originalEnd = previousOriginal
            replacementEnd = previousReplacement
        }

        let changedOriginal = original[originalStart..<originalEnd]
        let changedReplacement = replacement[replacementStart..<replacementEnd]
        guard !changedOriginal.isEmpty || !changedReplacement.isEmpty else { return nil }

        return NarrowedTextSpan(
            originalUTF16Range: NSRange(originalStart..<originalEnd, in: original),
            originalText: String(changedOriginal),
            replacement: String(changedReplacement)
        )
    }
}
