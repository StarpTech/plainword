import Foundation
@testable import PlainwordCore
import XCTest

/// What a host is asked before it is written to, and why a narrowed write cannot ask it
/// about itself.
final class WriteConfirmationTests: XCTestCase {
    private let paragraph =
        "The meeting is at 3pm. Please let me no if that works for you, and I will "
        + "send an invitation over this afternoon."

    // MARK: - A write the host can refuse

    func testAnInsertionGrowsUntilThereIsSomethingToConfirm() {
        let text = "Hi Bob how are you" as NSString
        let range = NSRange(location: 6, length: 0)

        let confirmable = WriteConfirmation.confirmableRange(
            range,
            in: text,
            bounds: NSRange(location: 0, length: text.length)
        )

        XCTAssertEqual(confirmable, NSRange(location: 5, length: 1))
        XCTAssertEqual(text.substring(with: confirmable), "b")
    }

    func testAnInsertionAtALineStartTakesTheCharacterAfterItRatherThanTheBreak() {
        let text = "Hi Bob,\nthanks" as NSString
        let range = NSRange(location: 8, length: 0)

        let confirmable = WriteConfirmation.confirmableRange(
            range,
            in: text,
            bounds: NSRange(location: 0, length: text.length)
        )

        XCTAssertEqual(text.substring(with: confirmable), "t")
    }

    func testAnInsertionOnABlankLineIsLeftAsItIs() {
        // Nothing either side but structure the editor owns. There is no character to
        // take, and taking a line break is what the whole write shaping exists to avoid.
        let text = "Hi Bob,\n\nthanks" as NSString
        let range = NSRange(location: 8, length: 0)

        let confirmable = WriteConfirmation.confirmableRange(
            range,
            in: text,
            bounds: NSRange(location: 0, length: text.length)
        )

        XCTAssertEqual(confirmable, range)
    }

    func testGrowingNeverReachesPastTheTarget() {
        let text = "Hi Bob how are you" as NSString
        let range = NSRange(location: 6, length: 0)

        let confirmable = WriteConfirmation.confirmableRange(
            range,
            in: text,
            bounds: NSRange(location: 6, length: 4)
        )

        // The character before is outside what the author asked to have edited, so the
        // one after it is taken instead.
        XCTAssertEqual(text.substring(with: confirmable), " ")
    }

    func testAWriteThatAlreadyCoversSomethingIsLeftAlone() {
        let text = paragraph as NSString
        let range = NSRange(location: 37, length: 2)

        XCTAssertEqual(
            WriteConfirmation.confirmableRange(
                range,
                in: text,
                bounds: NSRange(location: 0, length: text.length)
            ),
            range
        )
    }

    func testGrowingTakesAWholeCharacterAndNeverHalfOfOne() {
        // An insertion after an emoji, which is two UTF-16 units, or four for a flag.
        // Growing by "one unit" would select half a character and hand the editor back
        // the wreckage of it.
        for text in ["Bis später 🇩🇪", "Bis später 😀", "Bis später é"] {
            let source = text as NSString
            let range = NSRange(location: source.length, length: 0)

            let confirmable = WriteConfirmation.confirmableRange(
                range,
                in: source,
                bounds: NSRange(location: 0, length: source.length)
            )

            let grown = source.substring(with: confirmable)
            XCTAssertEqual(grown.count, 1, "one whole character of \(text)")
            XCTAssertEqual(
                source.rangeOfComposedCharacterSequences(for: confirmable),
                confirmable
            )
        }
    }

    // MARK: - The surroundings

    func testTheNeighbourhoodIsWritingAHostCannotAnswerByAccident() {
        let text = paragraph as NSString
        let typo = text.range(of: "no")
        let neighbourhood = WriteConfirmation.neighbourhoodRange(for: typo, in: text)
        let confirmation = text.substring(with: neighbourhood)

        // "no" is in the paragraph twice over once "not" and "no" are both counted, and
        // two characters is what a narrowed write covers. Its surroundings are not.
        XCTAssertGreaterThan(confirmation.count, 40)
        XCTAssertEqual(occurrences(of: confirmation, in: paragraph), 1)
    }

    func testTheNeighbourhoodStopsAtTheEndsOfTheText() {
        let text = "Short." as NSString
        let neighbourhood = WriteConfirmation.neighbourhoodRange(
            for: NSRange(location: 0, length: 5),
            in: text
        )

        XCTAssertEqual(neighbourhood, NSRange(location: 0, length: 6))
    }

    func testTheNeighbourhoodNeverBeginsOrEndsInsideACharacter() {
        // Fifty flags either side, so both edges of the window land in the middle of a
        // surrogate pair unless something moves them.
        let flags = String(repeating: "🇬🇧", count: 50)
        let text = (flags + "typo" + flags) as NSString
        let range = text.range(of: "typo")

        let neighbourhood = WriteConfirmation.neighbourhoodRange(for: range, in: text)
        let confirmation = text.substring(with: neighbourhood)

        XCTAssertEqual(
            text.rangeOfComposedCharacterSequences(for: neighbourhood),
            neighbourhood,
            "the window has to be whole characters, or neither side can compare it"
        )
        XCTAssertTrue(confirmation.hasPrefix("🇬🇧"))
        XCTAssertTrue(confirmation.hasSuffix("🇬🇧"))
    }

    // MARK: - Comparing two readings

    func testTheSpacesAnEditorSubstitutesAreNotAMoveInTheText() {
        XCTAssertTrue(WriteConfirmation.matches("end of line ", "end of line\u{00a0}"))
        XCTAssertTrue(WriteConfirmation.matches("a\u{202f}b", "a b"))
    }

    func testTextThatMovedIsNeverComparedAway() {
        XCTAssertFalse(WriteConfirmation.matches("the cat sat", "he cat sat "))
        XCTAssertFalse(WriteConfirmation.matches("the cat sat", "the cat sa"))
    }

    func testComparingNeverChangesHowLongTheTextIs() {
        let text = "one\u{00a0}two\u{2007}three\u{202f}four\u{feff}"

        XCTAssertEqual(
            (WriteConfirmation.comparable(text) as NSString).length,
            (text as NSString).length
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        let source = haystack as NSString
        var found = 0
        var location = 0
        while location < source.length {
            let range = source.range(
                of: needle,
                range: NSRange(location: location, length: source.length - location)
            )
            guard range.location != NSNotFound else { break }
            found += 1
            location = range.location + 1
        }
        return found
    }
}
