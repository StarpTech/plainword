import Foundation

/// What a host has to be holding before a write is made against it.
///
/// A write is addressed by a number: select these characters, put those there instead.
/// The number means whatever it means in the host's own text, and the plan that produced
/// it counted in a copy that was read out earlier, through a different attribute. Only
/// the host can say whether the two agree, and a browser-backed editor is where they
/// sometimes do not: an offset measured against the value an editor published can
/// address different writing by the time it is handed back as a selection.
///
/// The guard against that was the text of the selection itself — select the range, ask
/// the host what it is holding, refuse if it is not what the plan said. That is a real
/// question while a write covers a paragraph, because a paragraph is unique writing. It
/// stops being one as soon as writes are narrowed to what a correction actually changed,
/// because what they then cover is a word, two characters, or nothing at all: `know`,
/// `no`, `,`, ``. A document holds those in dozens of places and holds the last one
/// everywhere, so a selection that landed in the wrong place answers with exactly what
/// the plan expected, and the write goes in there.
///
/// So the confirmation is taken from around the write instead of from inside it. Forty
/// characters either side is unique writing again, it is read through the same
/// range-parameterized attribute the selection offsets belong to, and it costs one round
/// trip. A write whose surroundings do not read as the plan says they should is a write
/// aimed at the wrong place, and the only safe thing to do with it is nothing.
public enum WriteConfirmation {
    /// How far either side of a write the host is asked to confirm. Long enough to be
    /// unique in a paragraph, short enough that reading it is one cheap question.
    public static let neighbourhoodPadding = 40

    /// The range whose text the host is asked to confirm before `range` is written.
    ///
    /// Never cut through a composed character sequence, because a host asked for half of
    /// an emoji answers something neither side can compare.
    public static func neighbourhoodRange(for range: NSRange, in text: NSString) -> NSRange {
        let start = characterStart(
            at: max(0, range.location - neighbourhoodPadding),
            in: text
        )
        let end = characterEnd(
            at: min(text.length, NSMaxRange(range) + neighbourhoodPadding),
            in: text
        )
        return NSRange(location: start, length: max(0, end - start))
    }

    /// A range the host can be asked about, which a zero-length one is not.
    ///
    /// A correction that only adds something — the comma in "Hi Bob, how are you" — is
    /// narrowed to an insertion, and an insertion selects nothing. Nothing is what every
    /// position in the document is holding, so the host cannot refuse it however wrong
    /// the place is, and a collapsed selection is also the one kind Chromium spells two
    /// ways: the end of a line and the start of the next are the same caret, and it does
    /// not always agree with itself about which one it was handed.
    ///
    /// Taking one neighbouring character into the write settles both. The character is
    /// written back exactly as it was, which costs it whatever styling it was carrying —
    /// one character's worth, against a sentence inserted where nobody looked.
    ///
    /// The character before is preferred, because the writing an insertion belongs to is
    /// usually to its left. A line break is never taken: a write that carries one asks
    /// the editor to rebuild structure it owns. Between two line breaks there is nothing
    /// to take, and the range is returned as it came.
    public static func confirmableRange(
        _ range: NSRange,
        in text: NSString,
        bounds: NSRange
    ) -> NSRange {
        guard range.length == 0,
              range.location >= bounds.location,
              NSMaxRange(range) <= NSMaxRange(bounds) else {
            return range
        }

        if range.location > bounds.location {
            let previous = text.rangeOfComposedCharacterSequence(at: range.location - 1)
            if previous.location >= bounds.location, !isLineBreak(previous, in: text) {
                return previous
            }
        }
        if range.location < NSMaxRange(bounds) {
            let next = text.rangeOfComposedCharacterSequence(at: range.location)
            if NSMaxRange(next) <= NSMaxRange(bounds), !isLineBreak(next, in: text) {
                return next
            }
        }
        return range
    }

    /// The form two readings of the same writing are compared in.
    ///
    /// A rich-text editor stores the space at the end of a line, and the second of two
    /// consecutive spaces, as a non-breaking one, and which of the two spellings comes
    /// back can depend on which attribute was asked. That is the same writing in the same
    /// place, and refusing to write because of it would leave the correction unapplied
    /// for a reason nobody could see.
    ///
    /// Every substitution here is one UTF-16 unit for one UTF-16 unit, so nothing this
    /// does can hide the thing it is being used to detect: text that has moved.
    public static func comparable(_ text: String) -> String {
        String(text.map { interchangeableSpaces.contains($0) ? " " : $0 })
    }

    /// Whether two readings of the same range are the same writing.
    public static func matches(_ text: String, _ other: String) -> Bool {
        comparable(text) == comparable(other)
    }

    /// The spaces an editor substitutes for one another. Each is a single UTF-16 unit.
    private static let interchangeableSpaces: Set<Character> = [
        "\u{00a0}", // no-break space
        "\u{2007}", // figure space
        "\u{202f}", // narrow no-break space
        "\u{2009}", // thin space
        "\u{feff}"  // zero-width no-break space, which some editors park at a line end
    ]

    private static func isLineBreak(_ range: NSRange, in text: NSString) -> Bool {
        text.substring(with: range).contains(where: \.isNewline)
    }

    /// The start of whatever character `location` is inside, so a neighbourhood never
    /// begins half-way through one.
    private static func characterStart(at location: Int, in text: NSString) -> Int {
        guard location > 0, location < text.length else { return location }
        return text.rangeOfComposedCharacterSequence(at: location).location
    }

    /// The end of whatever character `location` is inside, for the same reason.
    private static func characterEnd(at location: Int, in text: NSString) -> Int {
        guard location > 0, location < text.length else { return location }
        let sequence = text.rangeOfComposedCharacterSequence(at: location)
        return sequence.location == location ? location : NSMaxRange(sequence)
    }
}
