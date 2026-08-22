import Foundation

/// One line's worth of a correction, addressed to the line and to nothing around it.
public struct TextLineEdit: Equatable, Sendable {
    /// Where the line sits in the original target text, excluding its line break.
    public let originalUTF16Range: NSRange
    /// What the line holds now, which the write is expected to be replacing.
    public let originalText: String
    /// What the line should hold instead. Never contains a line break.
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

/// Splits a correction into per-line writes that never span a line break.
///
/// A rich-text editor does not store a blank line as a character. Gmail, Outlook on the
/// web, Superhuman, and Mail all spell one as an empty block element, and the newline an
/// accessibility client reads back is a rendering of that structure rather than
/// something the document actually contains. Hand such an editor a multi-paragraph
/// string and it inserts the line breaks as literal characters inside one text node,
/// where HTML whitespace collapsing renders them as a single space. The paragraphs merge
/// on screen while the accessibility layer still reports the characters that were
/// written, so the write verifies as a success and the author is the one who finds out.
///
/// The way past it is to never ask the editor to reproduce a line break. Each line is
/// corrected in place, inside its own write, and the breaks between them are neither
/// selected nor rewritten: whatever structure the editor is holding them in is simply
/// left alone. Lines that did not change are not written at all.
///
/// This only works while both sides agree on how the text is divided up. A correction
/// that merges two paragraphs or splits one has changed the structure on purpose, and
/// there is no line-for-line pairing to write; those are reported as unplannable so the
/// caller can fall back to replacing the block as a whole.
public enum LineSegmentedEditPlanner {
    /// Beyond this the per-line writes stop being cheaper than the single write they
    /// replace: every one of them is a selection, a write, and a verification against
    /// the host, and a correction touching this many lines is a rewrite of the document
    /// rather than a repair of a few sentences.
    public static let maximumSegmentCount = 24

    /// Returns the writes that turn `original` into `replacement` one line at a time,
    /// or `nil` when the two cannot be paired line for line.
    public static func plan(original: String, replacement: String) -> [TextLineEdit]? {
        let originalLines = lines(in: original)
        let replacementLines = lines(in: replacement)
        guard originalLines.count == replacementLines.count else { return nil }

        var edits: [TextLineEdit] = []
        for (originalLine, replacementLine) in zip(originalLines, replacementLines) {
            // The breaks are what this whole exercise exists to preserve, so a
            // correction that respelled one is a correction that has to be written as a
            // block. In practice they always match: a model that returns the author's
            // line breaks returns the author's line breaks.
            guard originalLine.separator == replacementLine.separator else { return nil }
            guard originalLine.text != replacementLine.text else { continue }
            edits.append(
                TextLineEdit(
                    originalUTF16Range: originalLine.range,
                    originalText: originalLine.text,
                    replacement: replacementLine.text
                )
            )
        }

        guard !edits.isEmpty, edits.count <= maximumSegmentCount else { return nil }
        return edits
    }

    private struct Line {
        let text: String
        /// The line's own characters, without the break that ends it.
        let range: NSRange
        /// The break that ends the line, empty for the last line of the text.
        let separator: String
    }

    private static func lines(in text: String) -> [Line] {
        let source = text as NSString
        var lines: [Line] = []
        var lineStart = 0
        var index = 0

        while index < source.length {
            let character = source.character(at: index)
            guard let scalar = UnicodeScalar(character),
                  CharacterSet.newlines.contains(scalar) else {
                index += 1
                continue
            }
            // A carriage return and the line feed after it are one break, not two
            // lines with an empty one between them.
            var separatorEnd = index + 1
            if character == 0x000D,
               separatorEnd < source.length,
               source.character(at: separatorEnd) == 0x000A {
                separatorEnd += 1
            }
            let lineRange = NSRange(location: lineStart, length: index - lineStart)
            lines.append(
                Line(
                    text: source.substring(with: lineRange),
                    range: lineRange,
                    separator: source.substring(
                        with: NSRange(location: index, length: separatorEnd - index)
                    )
                )
            )
            index = separatorEnd
            lineStart = separatorEnd
        }

        let lastRange = NSRange(location: lineStart, length: source.length - lineStart)
        lines.append(
            Line(
                text: source.substring(with: lastRange),
                range: lastRange,
                separator: ""
            )
        )
        return lines
    }
}
