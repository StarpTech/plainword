import Foundation

/// Finds where an author's signature begins, so an edit can stop before it.
///
/// A signature is not writing the author is doing; it is a block the mail client puts
/// there. Sending it for correction spends tokens on text nobody asked about, invites a
/// model to restyle a job title or a phone number into something it prefers, and every
/// such edit has to be written back as plain characters, which is what takes the links,
/// the weight, and the layout out of it. Excluding it removes all of that at once. It
/// It is left out of the request altogether rather than sent as context, because a
/// correction has no use for it: nothing in a name and a phone number tells a model
/// whether the sentence above them is spelled correctly.
///
/// Two shapes are recognised, both conservative, because the cost of a wrong answer is
/// asymmetric: refusing to correct a real signature is invisible, while cutting the last
/// paragraph of a message out of the correction is not.
public enum SignatureBoundary {
    /// How many lines a trailing block may run to and still be read as a signature.
    /// Long enough for a name, a title, a company, a phone number, and an address line.
    private static let maximumTrailingLines = 6

    /// How long a line in one may be. A signature is a stack of short labels; prose is
    /// not, and a hard-wrapped closing paragraph that happens to carry a phone number
    /// is exactly what this keeps out of the answer.
    private static let maximumLineLength = 60

    /// Where the signature starts, or `nil` when the text does not appear to hold one.
    ///
    /// The answer is a UTF-16 offset into `text`, at the start of the signature's first
    /// line, with the blank line above it left on the message side.
    public static func location(in text: String) -> Int? {
        let source = text as NSString
        guard source.length > 0 else { return nil }

        let lines = lineRanges(in: source)
        if let delimiter = delimiterLocation(lines: lines, source: source) {
            return delimiter
        }
        return contactBlockLocation(lines: lines, source: source)
    }

    /// The conventional delimiter: a line holding two hyphens and nothing else but
    /// space. Mail clients have written it for forty years and it means precisely this.
    private static func delimiterLocation(lines: [NSRange], source: NSString) -> Int? {
        for (index, line) in lines.enumerated().reversed() {
            let text = source.substring(with: line)
            guard text.trimmingCharacters(in: .whitespaces) == "--" else { continue }
            // A delimiter with the whole message under it, or with no message above it,
            // is not a delimiter.
            guard lines.count - index - 1 <= maximumTrailingLines,
                  holdsMessage(before: line.location, in: source) else {
                return nil
            }
            return line.location
        }
        return nil
    }

    /// The other shape: a short block at the very end, separated from the message by a
    /// blank line, carrying something no one writes in a sentence — an email address, a
    /// web address, or a phone number.
    ///
    /// Those three are what make this safe to act on. A closing paragraph of prose does
    /// not carry them, and a block that does is a block whose formatting is worth more
    /// than a correction to it would be.
    private static func contactBlockLocation(lines: [NSRange], source: NSString) -> Int? {
        var blockStart: Int?
        var blockLines: [NSRange] = []
        for line in lines.reversed() {
            let text = source.substring(with: line)
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line closes the block, unless the block is still empty, which
                // is what trailing blank lines at the end of a field look like.
                if blockLines.isEmpty { continue }
                break
            }
            guard blockLines.count < maximumTrailingLines,
                  line.length <= maximumLineLength else {
                return nil
            }
            blockLines.append(line)
            blockStart = line.location
        }

        guard let blockStart,
              !blockLines.isEmpty,
              holdsMessage(before: blockStart, in: source) else {
            return nil
        }
        let carriesContactDetail = blockLines.contains { line in
            holdsContactDetail(source.substring(with: line))
        }
        return carriesContactDetail ? blockStart : nil
    }

    /// Whether there is anything above the boundary for the correction to work on. A
    /// field holding nothing but a signature is a field whose signature is the message.
    private static func holdsMessage(before location: Int, in source: NSString) -> Bool {
        guard location > 0 else { return false }
        return source
            .substring(to: location)
            .contains { !$0.isWhitespace }
    }

    private static func holdsContactDetail(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return contactDetailPattern?.firstMatch(in: line, range: range) != nil
    }

    /// An email address, a web address, or a run of digits long enough to be a phone
    /// number and punctuated the way one is.
    private static let contactDetailPattern = try? NSRegularExpression(
        pattern: [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"(https?://|www\.)\S+"#,
            #"(\+|\()?\d[\d\s().-]{7,}\d"#
        ].joined(separator: "|"),
        options: [.caseInsensitive]
    )

    private static func lineRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            // The break belongs to the line above, not to the one starting after it.
            let content = source.rangeOfCharacter(
                from: .newlines,
                options: .backwards,
                range: line
            )
            ranges.append(
                content.location == NSNotFound
                    ? line
                    : NSRange(location: line.location, length: content.location - line.location)
            )
            location = NSMaxRange(line)
        }
        return ranges
    }
}
