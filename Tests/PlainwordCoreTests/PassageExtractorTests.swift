import Foundation
import XCTest
@testable import PlainwordCore

/// The passage extractor answers one question: how much of the author's own writing
/// travels alongside an edit, and where its far edge lands. The rule it replaced counted
/// neighbouring sentences, which measured lines rather than meaning.
final class PassageExtractorTests: XCTestCase {
    private let sentences = "First. Second. Third. Fourth. Fifth. Sixth. Seventh."

    private func target(_ needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    // MARK: - Budget

    func testTakesEverythingWhenTheBudgetCoversIt() {
        let target = target("Fourth.", in: sentences)
        let passage = PassageExtractor.before(
            target,
            in: sentences,
            budget: PassageBudget(maximumUTF16Length: 400)
        )

        XCTAssertEqual(passage.text, "First. Second. Third.")
        XCTAssertFalse(passage.wasTruncated)
    }

    func testNeverExceedsItsBudget() {
        for limit in 1...40 {
            let passage = PassageExtractor.before(
                target("Seventh.", in: sentences),
                in: sentences,
                budget: PassageBudget(maximumUTF16Length: limit)
            )
            XCTAssertLessThanOrEqual(
                (passage.text as NSString).length,
                limit,
                "leading passage overran a budget of \(limit)"
            )
        }

        for limit in 1...40 {
            let passage = PassageExtractor.after(
                target("First.", in: sentences),
                in: sentences,
                budget: PassageBudget(maximumUTF16Length: limit)
            )
            XCTAssertLessThanOrEqual(
                (passage.text as NSString).length,
                limit,
                "trailing passage overran a budget of \(limit)"
            )
        }
    }

    func testAZeroBudgetSendsNothing() {
        XCTAssertEqual(
            PassageExtractor.before(
                target("Fourth.", in: sentences),
                in: sentences,
                budget: .none
            ),
            .empty
        )
        XCTAssertEqual(
            PassageExtractor.after(
                target("Fourth.", in: sentences),
                in: sentences,
                budget: .none
            ),
            .empty
        )
    }

    // MARK: - Edges

    func testLeadingEdgeMovesInwardToASentenceStart() {
        // A budget of 18 reaches back into "First."; the edge moves forward to the start
        // of "Second." rather than beginning the passage mid-word.
        let passage = PassageExtractor.before(
            target("Fourth.", in: sentences),
            in: sentences,
            budget: PassageBudget(maximumUTF16Length: 18, preferredBoundary: .sentence)
        )

        XCTAssertEqual(passage.text, "Second. Third.")
        XCTAssertTrue(passage.wasTruncated)
    }

    func testTrailingEdgeMovesInwardToASentenceEnd() {
        let passage = PassageExtractor.after(
            target("First.", in: sentences),
            in: sentences,
            budget: PassageBudget(maximumUTF16Length: 18, preferredBoundary: .sentence)
        )

        XCTAssertEqual(passage.text, "Second. Third.")
        XCTAssertTrue(passage.wasTruncated)
    }

    func testFallsBackToAWordEdgeWhenNoSentenceFits() {
        let text = "One very long sentence that never ends with punctuation at all here"
        let passage = PassageExtractor.before(
            NSRange(location: (text as NSString).length, length: 0),
            in: text,
            budget: PassageBudget(maximumUTF16Length: 12, preferredBoundary: .sentence)
        )

        XCTAssertFalse(passage.text.isEmpty)
        XCTAssertLessThanOrEqual((passage.text as NSString).length, 12)
        // Whatever it kept, it began at a word.
        XCTAssertTrue(text.contains(" \(passage.text)"))
    }

    func testParagraphBoundaryKeepsWholeParagraphs() {
        let text = "Opening paragraph here.\n\nMiddle paragraph here.\n\nClosing paragraph."
        let passage = PassageExtractor.before(
            target("Closing paragraph.", in: text),
            in: text,
            budget: PassageBudget(maximumUTF16Length: 40, preferredBoundary: .paragraph)
        )

        XCTAssertEqual(passage.text, "Middle paragraph here.")
        XCTAssertTrue(passage.wasTruncated)
    }

    // MARK: - The case from the Notes screenshot

    func testACaretOnABlankLineKeepsThePrecedingParagraphs() {
        let note = """
        Yesterday me and my freind went to the store because we was needing some \
        grocieries. The weather were really nice, so we decide to walk instead of \
        taking the car. We buyed some apples, bread, milk and a bunch of choclate.

        After that

        """
        let caret = (note as NSString).length
        let passage = PassageExtractor.before(
            NSRange(location: caret, length: 0),
            in: note,
            budget: ContextNeed.hungry.leading
        )

        // The old rule stopped at the previous sentence, which here was "After that".
        XCTAssertTrue(passage.text.hasPrefix("Yesterday me and my freind"))
        XCTAssertTrue(passage.text.hasSuffix("After that"))
        XCTAssertFalse(passage.wasTruncated)
    }

    // MARK: - Boundaries of the input

    func testHandlesTargetsAtEitherEndOfTheText() {
        XCTAssertEqual(
            PassageExtractor.before(
                NSRange(location: 0, length: 0),
                in: sentences,
                budget: .init(maximumUTF16Length: 100)
            ),
            .empty
        )
        XCTAssertEqual(
            PassageExtractor.after(
                NSRange(location: (sentences as NSString).length, length: 0),
                in: sentences,
                budget: .init(maximumUTF16Length: 100)
            ),
            .empty
        )
    }

    func testHandlesAnEmptyDocument() {
        XCTAssertEqual(
            PassageExtractor.before(
                NSRange(location: 0, length: 0),
                in: "",
                budget: .init(maximumUTF16Length: 100)
            ),
            .empty
        )
        XCTAssertEqual(
            PassageExtractor.after(
                NSRange(location: 0, length: 0),
                in: "",
                budget: .init(maximumUTF16Length: 100)
            ),
            .empty
        )
    }

    /// A budget that lands in the middle of an emoji must not split it, and must not
    /// quietly spend more than it was given to avoid doing so.
    func testNeverSplitsACharacterSequence() {
        let text = "Family time 👨‍👩‍👧‍👦 and then some more text after it."
        let end = NSRange(location: (text as NSString).length, length: 0)

        for limit in 1...50 {
            let passage = PassageExtractor.before(
                end,
                in: text,
                budget: PassageBudget(maximumUTF16Length: limit, preferredBoundary: .word)
            )
            XCTAssertLessThanOrEqual((passage.text as NSString).length, limit)
            guard !passage.text.isEmpty else { continue }
            // A passage that split the emoji would not appear in the source text, and a
            // whole one is always a substring of it.
            XCTAssertTrue(
                text.contains(passage.text),
                "budget \(limit) produced a passage that is not part of the text"
            )
        }
    }

    // MARK: - Marking

    func testATruncatedPassageIsMarkedOnTheSideItWasCut() {
        let cut = Passage(text: "some writing", wasTruncated: true)
        XCTAssertEqual(cut.marked(.leading), "\(ReadOnlyContextRanker.elisionMarker) some writing")
        XCTAssertEqual(cut.marked(.trailing), "some writing \(ReadOnlyContextRanker.elisionMarker)")

        let whole = Passage(text: "some writing", wasTruncated: false)
        XCTAssertEqual(whole.marked(.leading), "some writing")
        XCTAssertEqual(whole.marked(.trailing), "some writing")

        XCTAssertEqual(Passage(text: "", wasTruncated: true).marked(.leading), "")
    }
}

final class ContextNeedTests: XCTestCase {
    func testADraftAsksForMoreThanAnEditDoes() {
        XCTAssertGreaterThan(
            ContextNeed.hungry.leading.maximumUTF16Length,
            ContextNeed.modest.leading.maximumUTF16Length
        )
        // Writing continues forwards, so what came before matters more than what follows.
        XCTAssertGreaterThan(
            ContextNeed.hungry.leading.maximumUTF16Length,
            ContextNeed.hungry.trailing.maximumUTF16Length
        )
    }

    func testAWholeFieldTargetAsksForNothingAround() {
        XCTAssertTrue(ContextNeed(.document).sendsNothing)
        XCTAssertFalse(ContextNeed(.insertionPoint).sendsNothing)
        XCTAssertFalse(ContextNeed(.sentence).sendsNothing)
    }

    func testTargetKindsMapToTheirNeed() {
        XCTAssertEqual(ContextNeed(.insertionPoint), .hungry)
        XCTAssertEqual(ContextNeed(.selection), .modest)
        XCTAssertEqual(ContextNeed(.sentence), .modest)
        XCTAssertEqual(ContextNeed(.paragraph), .modest)
        XCTAssertEqual(ContextNeed(.document), .identityOnly)
    }

    func testScalingShrinksBothSidesAndKeepsTheirEdges() {
        let scaled = ContextNeed.hungry.scaled(by: 0.5)

        XCTAssertEqual(scaled.leading.maximumUTF16Length, 600)
        XCTAssertEqual(scaled.trailing.maximumUTF16Length, 200)
        XCTAssertEqual(scaled.leading.preferredBoundary, .paragraph)
        XCTAssertEqual(ContextNeed.hungry.scaled(by: 1), .hungry)
    }
}
