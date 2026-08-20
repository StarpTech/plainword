import Foundation

/// The coarsest natural break a passage's outer edge may be moved to.
///
/// Ordered from finest to coarsest, so a budget that cannot reach a paragraph start can
/// fall back through the smaller units rather than giving up on a clean edge entirely.
public enum PassageBoundary: Int, Comparable, CaseIterable, Sendable {
    case word
    case sentence
    case paragraph

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// This boundary and every coarser one, coarsest first — the order they are tried in.
    fileprivate var descendingFromHere: [PassageBoundary] {
        PassageBoundary.allCases.filter { $0 <= self }.reversed()
    }
}

/// How much of the author's own writing may travel alongside an edit target, and where
/// the far edge of it is allowed to land.
public struct PassageBudget: Equatable, Hashable, Sendable {
    public let maximumUTF16Length: Int
    public let preferredBoundary: PassageBoundary

    public init(maximumUTF16Length: Int, preferredBoundary: PassageBoundary = .sentence) {
        self.maximumUTF16Length = max(0, maximumUTF16Length)
        self.preferredBoundary = preferredBoundary
    }

    /// Sends nothing. Used where the target is the whole field and there is no "around".
    public static let none = PassageBudget(
        maximumUTF16Length: 0,
        preferredBoundary: .word
    )
}

/// A span of the author's writing on one side of an edit target.
public struct Passage: Equatable, Sendable {
    public let text: String
    /// Whether writing was left out beyond the far edge. The prompt marks a truncated
    /// passage so that a fragment starting mid-thought is not read as a fresh start.
    public let wasTruncated: Bool

    public init(text: String, wasTruncated: Bool) {
        self.text = text
        self.wasTruncated = wasTruncated
    }

    public static let empty = Passage(text: "", wasTruncated: false)

    /// The passage as it travels in a request, carrying the elision marker when the
    /// text it continues from was left behind.
    public func marked(_ edge: PassageEdge) -> String {
        guard wasTruncated, !text.isEmpty else { return text }
        let marker = ReadOnlyContextRanker.elisionMarker
        return edge == .leading ? "\(marker) \(text)" : "\(text) \(marker)"
    }
}

public enum PassageEdge: Sendable {
    case leading
    case trailing
}

/// Takes the writing on either side of an edit target, to a budget.
///
/// This replaces counting neighbouring sentences. Counting sounds tidier but measures
/// the wrong thing: `enumerateSubstrings(.bySentences)` ends a sentence at a line break,
/// so in a note, a chat message, a list, or anything written in Markdown, one adjacent
/// sentence is one adjacent *line* — frequently two or three words. The budget is spent
/// first and the edge is then moved inward to the nearest clean break, which keeps the
/// result inside the allowance while never ending mid-word.
public enum PassageExtractor {
    /// The writing immediately before `target`, ending where the target begins.
    public static func before(
        _ target: NSRange,
        in text: String,
        budget: PassageBudget
    ) -> Passage {
        let source = text as NSString
        let end = min(max(target.location, 0), source.length)
        guard budget.maximumUTF16Length > 0, end > 0 else { return .empty }

        let rawStart = max(0, end - budget.maximumUTF16Length)
        var start = rawStart
        if rawStart > 0 {
            start = snappedStart(
                atOrAfter: rawStart,
                before: end,
                boundary: budget.preferredBoundary,
                in: text,
                source: source
            ) ?? graphemeAlignedStart(rawStart, in: source)
        }
        guard end > start else { return .empty }

        let trimmed = source
            .substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A start that moved is one that left writing behind, whatever the trim did to
        // the whitespace around it.
        return Passage(text: trimmed, wasTruncated: rawStart > 0 && !trimmed.isEmpty)
    }

    /// The writing immediately after `target`, starting where the target ends.
    public static func after(
        _ target: NSRange,
        in text: String,
        budget: PassageBudget
    ) -> Passage {
        let source = text as NSString
        let start = min(max(NSMaxRange(target), 0), source.length)
        guard budget.maximumUTF16Length > 0, start < source.length else { return .empty }

        let rawEnd = min(source.length, start + budget.maximumUTF16Length)
        var end = rawEnd
        if rawEnd < source.length {
            end = snappedEnd(
                atOrBefore: rawEnd,
                after: start,
                boundary: budget.preferredBoundary,
                in: text,
                source: source
            ) ?? graphemeAlignedEnd(rawEnd, in: source)
        }
        guard end > start else { return .empty }

        let trimmed = source
            .substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Passage(
            text: trimmed,
            wasTruncated: rawEnd < source.length && !trimmed.isEmpty
        )
    }

    // MARK: - Snapping

    /// The first clean break at or after `location`, trying the coarsest allowed unit
    /// first. Searching forward rather than backward is what keeps the passage inside
    /// its budget: moving the edge outward would spend an allowance it does not have.
    private static func snappedStart(
        atOrAfter location: Int,
        before limit: Int,
        boundary: PassageBoundary,
        in text: String,
        source: NSString
    ) -> Int? {
        for candidate in boundary.descendingFromHere {
            let start: Int?
            switch candidate {
            case .paragraph:
                start = paragraphStart(atOrAfter: location, before: limit, source: source)
            case .sentence:
                start = sentenceStart(
                    atOrAfter: location,
                    before: limit,
                    in: text,
                    source: source
                )
            case .word:
                start = wordStart(atOrAfter: location, before: limit, source: source)
            }
            if let start, start >= location, start < limit {
                return start
            }
        }
        return nil
    }

    private static func snappedEnd(
        atOrBefore location: Int,
        after floor: Int,
        boundary: PassageBoundary,
        in text: String,
        source: NSString
    ) -> Int? {
        for candidate in boundary.descendingFromHere {
            let end: Int?
            switch candidate {
            case .paragraph:
                end = paragraphEnd(atOrBefore: location, after: floor, source: source)
            case .sentence:
                end = sentenceEnd(
                    atOrBefore: location,
                    after: floor,
                    in: text,
                    source: source
                )
            case .word:
                end = wordEnd(atOrBefore: location, after: floor, source: source)
            }
            if let end, end <= location, end > floor {
                return end
            }
        }
        return nil
    }

    // MARK: - Paragraph breaks

    private static func paragraphStart(
        atOrAfter location: Int,
        before limit: Int,
        source: NSString
    ) -> Int? {
        guard location < source.length else { return nil }
        let containing = source.paragraphRange(for: NSRange(location: location, length: 0))
        let start = containing.location >= location
            ? containing.location
            : NSMaxRange(containing)
        return start < limit ? start : nil
    }

    private static func paragraphEnd(
        atOrBefore location: Int,
        after floor: Int,
        source: NSString
    ) -> Int? {
        guard location > 0, source.length > 0 else { return nil }
        let probe = min(max(location - 1, floor), source.length - 1)
        let containing = source.paragraphRange(for: NSRange(location: probe, length: 0))
        // A paragraph that finishes inside the budget ends the passage; one that
        // straddles the edge is dropped, leaving the passage at the previous break.
        let end = NSMaxRange(containing) <= location
            ? NSMaxRange(containing)
            : containing.location
        return end > floor ? end : nil
    }

    // MARK: - Sentence breaks

    /// Sentence enumeration is scoped to the enclosing paragraph rather than to the
    /// passage. Sentences never span a paragraph break, so the segmentation is identical
    /// — but starting the scan mid-sentence would make the tokenizer report that partial
    /// text as a sentence of its own, and the edge would snap to a break that is not one.
    private static func sentenceStart(
        atOrAfter location: Int,
        before limit: Int,
        in text: String,
        source: NSString
    ) -> Int? {
        guard location < source.length else { return nil }
        let windowStart = source
            .paragraphRange(for: NSRange(location: location, length: 0))
            .location
        guard let window = Range(
            NSRange(location: windowStart, length: limit - windowStart),
            in: text
        ) else {
            return nil
        }

        var found: Int?
        text.enumerateSubstrings(
            in: window,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, stop in
            let candidate = NSRange(range, in: text).location
            if candidate >= location {
                found = candidate
                stop = true
            }
        }
        return found
    }

    private static func sentenceEnd(
        atOrBefore location: Int,
        after floor: Int,
        in text: String,
        source: NSString
    ) -> Int? {
        guard location > 0, source.length > 0 else { return nil }
        let windowStart = source
            .paragraphRange(for: NSRange(location: min(floor, source.length - 1), length: 0))
            .location
        // The window runs to the end of the paragraph holding the edge, so the sentence
        // straddling it is segmented correctly and can then be rejected for overrunning.
        let windowEnd = NSMaxRange(
            source.paragraphRange(
                for: NSRange(location: min(location, source.length - 1), length: 0)
            )
        )
        guard windowEnd > windowStart,
              let window = Range(
                NSRange(location: windowStart, length: windowEnd - windowStart),
                in: text
              ) else {
            return nil
        }

        var found: Int?
        text.enumerateSubstrings(
            in: window,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let candidate = NSMaxRange(NSRange(range, in: text))
            if candidate <= location, candidate > floor {
                found = max(found ?? candidate, candidate)
            }
        }
        return found
    }

    // MARK: - Word breaks

    private static func wordStart(
        atOrAfter location: Int,
        before limit: Int,
        source: NSString
    ) -> Int? {
        guard location < source.length else { return nil }
        if location == 0 || isWhitespace(at: location - 1, in: source) {
            return location
        }
        let search = NSRange(location: location, length: limit - location)
        let whitespace = source.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: [],
            range: search
        )
        guard whitespace.location != NSNotFound else { return nil }
        let start = NSMaxRange(whitespace)
        return start < limit ? start : nil
    }

    private static func wordEnd(
        atOrBefore location: Int,
        after floor: Int,
        source: NSString
    ) -> Int? {
        guard location > 0 else { return nil }
        if location >= source.length || isWhitespace(at: location, in: source) {
            return location
        }
        let search = NSRange(location: floor, length: location - floor)
        let whitespace = source.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: .backwards,
            range: search
        )
        guard whitespace.location != NSNotFound else { return nil }
        return whitespace.location > floor ? whitespace.location : nil
    }

    // MARK: - Grapheme safety

    /// Moves an unsnapped start forward off the middle of a character sequence. Forward,
    /// because the alternative spends more than the budget allowed.
    private static func graphemeAlignedStart(_ location: Int, in source: NSString) -> Int {
        guard location > 0, location < source.length else {
            return min(max(location, 0), source.length)
        }
        let sequence = source.rangeOfComposedCharacterSequence(at: location)
        return sequence.location == location ? location : NSMaxRange(sequence)
    }

    private static func graphemeAlignedEnd(_ location: Int, in source: NSString) -> Int {
        guard location > 0, location < source.length else {
            return min(max(location, 0), source.length)
        }
        let sequence = source.rangeOfComposedCharacterSequence(at: location)
        return sequence.location == location ? location : sequence.location
    }

    private static func isWhitespace(at location: Int, in source: NSString) -> Bool {
        guard location >= 0, location < source.length else { return false }
        return source
            .substring(with: NSRange(location: location, length: 1))
            .allSatisfy(\.isWhitespace)
    }
}
