import Foundation

public enum TextEditTargetKind: String, Equatable, Sendable {
    case selection
    case sentence
    case paragraph
    case document
    /// An empty target at the caret: there is nothing to edit, so the request writes
    /// new text instead of revising existing text.
    case insertionPoint
}

public enum TextEditExtractionScope: Equatable, Sendable {
    case sentence
    case paragraph
    case document
}

public struct TextEditContext: Equatable, Sendable {
    public let text: String
    public let utf16Location: Int
    public let utf16Length: Int
    public let applicationContext: String
    public let applicationContextFragments: [ReadOnlyContextFragment]
    public let leadingContext: String
    public let trailingContext: String
    public let targetKind: TextEditTargetKind
    public let completionIsAllowed: Bool

    public init(
        text: String,
        utf16Location: Int,
        utf16Length: Int,
        applicationContext: String = "",
        applicationContextFragments: [ReadOnlyContextFragment] = [],
        leadingContext: String = "",
        trailingContext: String = "",
        targetKind: TextEditTargetKind = .sentence,
        completionIsAllowed: Bool = false
    ) {
        self.text = text
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
        self.applicationContext = applicationContext
        if applicationContextFragments.isEmpty,
           applicationContext.contains(where: { !$0.isWhitespace }) {
            self.applicationContextFragments = [
                .init(kind: .relatedContent, text: applicationContext)
            ]
        } else {
            self.applicationContextFragments = applicationContextFragments
        }
        self.leadingContext = leadingContext
        self.trailingContext = trailingContext
        self.targetKind = targetKind
        self.completionIsAllowed = completionIsAllowed
    }

    public var range: NSRange {
        NSRange(location: utf16Location, length: utf16Length)
    }

    public func withApplicationContext(
        _ applicationContextFragments: [ReadOnlyContextFragment]
    ) -> TextEditContext {
        TextEditContext(
            text: text,
            utf16Location: utf16Location,
            utf16Length: utf16Length,
            applicationContext: ReadOnlyContextRanker.plainText(
                from: applicationContextFragments
            ),
            applicationContextFragments: applicationContextFragments,
            leadingContext: leadingContext,
            trailingContext: trailingContext,
            targetKind: targetKind,
            completionIsAllowed: completionIsAllowed
        )
    }

    /// Returns a request context whose editable text has been revised while keeping
    /// the same source location and read-only surrounding context.
    public func withEditableText(_ text: String) -> TextEditContext {
        TextEditContext(
            text: text,
            utf16Location: utf16Location,
            utf16Length: (text as NSString).length,
            applicationContext: applicationContext,
            applicationContextFragments: applicationContextFragments,
            leadingContext: leadingContext,
            trailingContext: trailingContext,
            targetKind: targetKind,
            completionIsAllowed: completionIsAllowed
        )
    }

    public func translated(byUTF16Offset offset: Int) -> TextEditContext? {
        let translatedLocation = utf16Location + offset
        guard translatedLocation >= 0 else { return nil }
        return TextEditContext(
            text: text,
            utf16Location: translatedLocation,
            utf16Length: utf16Length,
            applicationContext: applicationContext,
            applicationContextFragments: applicationContextFragments,
            leadingContext: leadingContext,
            trailingContext: trailingContext,
            targetKind: targetKind,
            completionIsAllowed: completionIsAllowed
        )
    }
}

public enum TextEditContextExtractor {
    public static func extract(
        from fullText: String,
        selectedRange: NSRange,
        scope: TextEditExtractionScope = .sentence,
        maximumUTF16Length: Int = 1_600,
        surrounding: ContextNeed = .modest
    ) -> TextEditContext? {
        guard maximumUTF16Length > 0 else { return nil }

        let source = fullText as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location <= source.length,
              selectedRange.location + selectedRange.length <= source.length else {
            return nil
        }

        let candidate: NSRange
        let targetKind: TextEditTargetKind
        if selectedRange.length > 0 {
            guard selectedRange.length <= maximumUTF16Length else { return nil }
            candidate = selectedRange
            targetKind = .selection
        } else {
            let requestedRange: NSRange
            switch scope {
            case .sentence:
                requestedRange = sentenceRange(
                    in: fullText,
                    around: selectedRange.location
                ) ?? paragraphRange(in: source, around: selectedRange.location)
                targetKind = .sentence
            case .paragraph:
                requestedRange = paragraphRange(
                    in: source,
                    around: selectedRange.location
                )
                targetKind = .paragraph
            case .document:
                guard source.length <= maximumUTF16Length else { return nil }
                requestedRange = NSRange(location: 0, length: source.length)
                targetKind = .document
            }
            candidate = boundedRange(
                requestedRange,
                around: selectedRange.location,
                maximumLength: maximumUTF16Length,
                source: source
            )
        }

        let trimmed = trimmingWhitespace(from: candidate, source: source)
        guard trimmed.length > 0,
              trimmed.location + trimmed.length <= source.length else {
            return nil
        }

        let composed = source.rangeOfComposedCharacterSequences(for: trimmed)
        guard composed.length <= maximumUTF16Length else { return nil }

        let text = source.substring(with: composed)
        guard text.contains(where: { !$0.isWhitespace }) else { return nil }

        // The editable-target limit and the read-only context limit serve different
        // purposes. A long valid selection should not lose all of its context merely
        // because it approaches the edit limit.
        let need = (selectedRange.length > 0 || scope == .sentence)
            ? surrounding
            : .identityOnly

        return TextEditContext(
            text: text,
            utf16Location: composed.location,
            utf16Length: composed.length,
            leadingContext: PassageExtractor
                .before(composed, in: fullText, budget: need.leading)
                .marked(.leading),
            trailingContext: PassageExtractor
                .after(composed, in: fullText, budget: need.trailing)
                .marked(.trailing),
            targetKind: targetKind,
            completionIsAllowed: selectedRange.length == 0
                && scope == .sentence
                && completionIsAllowed(
                    at: selectedRange.location,
                    target: composed,
                    targetText: text,
                    source: source
                )
        )
    }

    /// Returns a zero-length target at a caret that has no text of its own to revise.
    ///
    /// `extract` deliberately refuses an empty target, because every editing request
    /// needs something to revise. Writing new text is the one case that does not, so it
    /// gets its own entry point rather than a flag that would loosen that rule for
    /// every caller.
    ///
    /// The caret qualifies whenever its own paragraph is blank, not only when the whole
    /// field is. A cursor resting on an empty line between two paragraphs is exactly
    /// where an author means to write something new, and refusing it there left the
    /// review shortcut with nothing to do at all.
    public static func insertionPoint(
        in fullText: String,
        at utf16Location: Int,
        surrounding: ContextNeed = .hungry
    ) -> TextEditContext? {
        let source = fullText as NSString
        guard utf16Location >= 0,
              utf16Location <= source.length,
              caretParagraphIsBlank(in: source, at: utf16Location) else {
            return nil
        }

        // Whatever surrounds a blank line is all the request has to write from, so it
        // travels as read-only context. An empty field simply has none of it.
        let caret = NSRange(location: utf16Location, length: 0)
        return TextEditContext(
            text: "",
            utf16Location: utf16Location,
            utf16Length: 0,
            leadingContext: PassageExtractor
                .before(caret, in: fullText, budget: surrounding.leading)
                .marked(.leading),
            trailingContext: PassageExtractor
                .after(caret, in: fullText, budget: surrounding.trailing)
                .marked(.trailing),
            targetKind: .insertionPoint
        )
    }

    public static func replacing(
        context: TextEditContext,
        in fullText: String,
        with correctedText: String
    ) -> String? {
        let source = fullText as NSString
        let range = context.range
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= source.length,
              source.substring(with: range) == context.text else {
            return nil
        }
        return source.replacingCharacters(in: range, with: correctedText)
    }

    private static func boundedRange(
        _ range: NSRange,
        around cursor: Int,
        maximumLength: Int,
        source: NSString
    ) -> NSRange {
        guard range.length > maximumLength else { return range }

        let rangeEnd = range.location + range.length
        let safeCursor = min(max(cursor, range.location), rangeEnd)
        let preferredBefore = min(safeCursor - range.location, maximumLength * 3 / 4)
        var start = safeCursor - preferredBefore
        var end = min(rangeEnd, start + maximumLength)

        if end - start < maximumLength {
            start = max(range.location, end - maximumLength)
        }

        let bounded = NSRange(location: start, length: end - start)
        let composed = source.rangeOfComposedCharacterSequences(for: bounded)
        let wordAligned = wordAlignedRange(
            composed,
            within: range,
            source: source
        )
        if wordAligned.length <= maximumLength {
            return wordAligned
        }

        end = max(start, end - (wordAligned.length - maximumLength))
        return NSRange(location: start, length: end - start)
    }

    private static func wordAlignedRange(
        _ proposed: NSRange,
        within container: NSRange,
        source: NSString
    ) -> NSRange {
        var start = proposed.location
        var end = NSMaxRange(proposed)
        let containerEnd = NSMaxRange(container)
        let whitespace = CharacterSet.whitespacesAndNewlines

        if start > container.location,
           start < source.length,
           !isWhitespace(at: start - 1, in: source),
           !isWhitespace(at: start, in: source) {
            let searchRange = NSRange(location: start, length: end - start)
            let boundary = source.rangeOfCharacter(from: whitespace, options: [], range: searchRange)
            if boundary.location != NSNotFound {
                start = NSMaxRange(boundary)
            }
        }

        if end < containerEnd,
           end > start,
           !isWhitespace(at: end - 1, in: source),
           !isWhitespace(at: end, in: source) {
            let searchRange = NSRange(location: start, length: end - start)
            let boundary = source.rangeOfCharacter(
                from: whitespace,
                options: .backwards,
                range: searchRange
            )
            if boundary.location != NSNotFound {
                end = boundary.location
            }
        }

        return end > start
            ? NSRange(location: start, length: end - start)
            : proposed
    }

    private static func isWhitespace(at location: Int, in source: NSString) -> Bool {
        guard location >= 0, location < source.length else { return false }
        return source.substring(with: NSRange(location: location, length: 1))
            .allSatisfy(\.isWhitespace)
    }

    private static func sentenceRange(in text: String, around utf16Location: Int) -> NSRange? {
        var containingRange: NSRange?
        var rangeStartingAtCursor: NSRange?

        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let candidate = NSRange(range, in: text)
            if candidate.location == utf16Location {
                rangeStartingAtCursor = candidate
            } else if utf16Location > candidate.location,
                      utf16Location <= NSMaxRange(candidate) {
                containingRange = candidate
            }
        }

        return rangeStartingAtCursor ?? containingRange
    }

    /// Reports whether the paragraph holding the caret carries no text.
    ///
    /// A caret at the very end of the text is treated as its own empty paragraph when
    /// the text ends in a line break, since that is where a trailing blank line puts it
    /// and `paragraphRange(for:)` would otherwise answer with the line above.
    private static func caretParagraphIsBlank(in source: NSString, at utf16Location: Int) -> Bool {
        guard source.length > 0 else { return true }
        let anchor = min(utf16Location, source.length - 1)
        if utf16Location >= source.length,
           source
            .substring(with: NSRange(location: anchor, length: 1))
            .allSatisfy(\.isNewline) {
            return true
        }
        let paragraph = source.paragraphRange(for: NSRange(location: anchor, length: 0))
        return source.substring(with: paragraph).allSatisfy(\.isWhitespace)
    }

    private static func paragraphRange(in source: NSString, around utf16Location: Int) -> NSRange {
        let anchor = source.length > 0
            ? min(max(0, utf16Location), source.length - 1)
            : 0
        return source.paragraphRange(for: NSRange(location: anchor, length: 0))
    }

    private static func completionIsAllowed(
        at caretLocation: Int,
        target: NSRange,
        targetText: String,
        source: NSString
    ) -> Bool {
        let targetEnd = NSMaxRange(target)
        guard caretLocation >= targetEnd,
              caretLocation <= source.length,
              let lastCharacter = targetText.last,
              !sentenceEndings.contains(lastCharacter) else {
            return false
        }

        let gap = NSRange(location: targetEnd, length: caretLocation - targetEnd)
        return source.substring(with: gap).allSatisfy(\.isWhitespace)
    }

    private static let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？"]

    private static func trimmingWhitespace(
        from range: NSRange,
        source: NSString
    ) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        let whitespace = CharacterSet.whitespacesAndNewlines

        while start < end,
              let scalar = UnicodeScalar(source.character(at: start)),
              whitespace.contains(scalar) {
            start += 1
        }
        while end > start,
              let scalar = UnicodeScalar(source.character(at: end - 1)),
              whitespace.contains(scalar) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }
}
