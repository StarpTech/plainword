import Foundation

/// Reconciles the caret offset a source reports with the text it handed over.
///
/// A caret resting at the end of a paragraph and one resting at the start of the next
/// are the same place on screen, and some editors publish the second spelling for both.
/// Chromium does: ask a `contenteditable` where its collapsed selection is while the
/// author is typing at the end of a line and the answer is the offset that *begins the
/// line below*. Every offset-based reading then agrees on the wrong paragraph, so a
/// review of "the paragraph at the cursor" proposes a rewrite of the line underneath the
/// one being written.
///
/// The offset alone cannot settle it — both positions are the same number. What settles
/// it is the text immediately before the caret, which the host can be asked for
/// separately: empty when the caret really is at the start of a line, and the line above
/// when it is not. Matching that text back against the captured document puts the offset
/// where the author is.
public enum CaretAlignment {
    /// How many line breaks a caret may be carried back across. A paragraph break is one
    /// or two; anything further apart is not the same position seen twice.
    public static let maximumSkippedLineBreaks = 8

    /// How much of the caret's line is matched. Enough to be unique in any real
    /// paragraph, short enough that the search stays a search.
    private static let maximumProbeLength = 120

    /// Whether a reported caret sits at the start of a line, which is the only place the
    /// two spellings of one position can be confused — and so the only place worth
    /// asking a host a second question about.
    public static func isAtLineStart(_ location: Int, in text: String) -> Bool {
        let source = text as NSString
        guard location > 0, location <= source.length else { return false }
        return source
            .substring(with: NSRange(location: location - 1, length: 1))
            .allSatisfy(\.isNewline)
    }

    /// Returns the offset in `text` that the caret is actually at.
    ///
    /// `lineBeforeCaret` is the writing between the start of the caret's line and the
    /// caret itself, as the host reports it — only the part after its last line break is
    /// used, so a probe that overran into the paragraph above costs nothing.
    ///
    /// The offset only moves backwards, only when the skipped writing is whitespace
    /// carrying a line break, and only when the line matches the captured text exactly.
    /// A caret that really is at the start of a paragraph reports no line before it and
    /// is left alone, as is every host that cannot answer the question at all.
    public static func resolved(
        reported: Int,
        lineBeforeCaret: String,
        in text: String,
        maximumSkippedLineBreaks: Int = maximumSkippedLineBreaks
    ) -> Int {
        let source = text as NSString
        guard reported > 0,
              reported <= source.length,
              isAtLineStart(reported, in: text) else {
            return reported
        }

        let line = currentLine(of: lineBeforeCaret)
        let probe = line as NSString
        guard probe.length > 0 else { return reported }

        let searchStart = max(0, reported - maximumSkippedLineBreaks - probe.length)
        let search = NSRange(location: searchStart, length: reported - searchStart)
        let match = source.range(of: line, options: .backwards, range: search)
        guard match.location != NSNotFound else { return reported }

        let end = NSMaxRange(match)
        guard end < reported else { return reported }
        let skipped = source.substring(with: NSRange(location: end, length: reported - end))
        guard skipped.allSatisfy(\.isWhitespace),
              skipped.contains(where: \.isNewline) else {
            return reported
        }
        return end
    }

    /// The part of a probe that belongs to the caret's own line, bounded.
    private static func currentLine(of lineBeforeCaret: String) -> String {
        let line = lineBeforeCaret
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .last
            .map(String.init) ?? lineBeforeCaret
        return String(line.suffix(maximumProbeLength))
    }
}
