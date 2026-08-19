import Foundation
import XCTest
@testable import PlainwordCore

final class TextEditContextTests: XCTestCase {
    func testSelectionTakesPriority() {
        let text = "First paragraph.\nSecond paragraph."
        let range = (text as NSString).range(of: "Second")

        let context = TextEditContextExtractor.extract(from: text, selectedRange: range)
        XCTAssertEqual(context?.text, "Second")
        XCTAssertEqual(context?.utf16Location, range.location)
        XCTAssertEqual(context?.utf16Length, range.length)
        XCTAssertEqual(context?.targetKind, .selection)
        XCTAssertEqual(context?.leadingContext, "First paragraph.")
        XCTAssertEqual(context?.trailingContext, "paragraph.")
    }

    func testTranslatesWindowRelativeContextToDocumentOffsets() throws {
        let context = TextEditContext(
            text: "paragraph",
            utf16Location: 20,
            utf16Length: 9,
            targetKind: .paragraph
        )

        let translated = try XCTUnwrap(context.translated(byUTF16Offset: 1_000))
        XCTAssertEqual(translated.utf16Location, 1_020)
        XCTAssertEqual(translated.text, context.text)
        XCTAssertNil(context.translated(byUTF16Offset: -21))
    }

    func testExtractsParagraphAtCursorWithoutTrailingNewline() {
        let text = "First paragraph.\nSecond paragraph.\n"
        let cursor = (text as NSString).range(of: "paragraph.", options: [], range: NSRange(location: 10, length: 25)).location

        XCTAssertEqual(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: cursor, length: 0)
            )?.text,
            "Second paragraph."
        )
    }

    func testExtractsOnlySentenceAtCursorWithReadOnlyContext() throws {
        let text = "The introduction is fine. This sentnce needs help. The ending is fine."
        let cursor = (text as NSString).range(of: "sentnce").location
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: cursor, length: 0)
            )
        )

        XCTAssertEqual(context.text, "This sentnce needs help.")
        XCTAssertEqual(context.leadingContext, "The introduction is fine.")
        XCTAssertEqual(context.trailingContext, "The ending is fine.")
    }

    func testParagraphScopeExtractsAllSentencesInPastedParagraph() throws {
        let text = "Yesterday me and my freind went to the store because we was needing some grocieries. The weather were really nice, so we decide to walk instead of taking the car. When we got their, I realised I had forgot my wallet at home! My friend sayed it wasnt a problem and she could pay for everything. We buyed some apples, bread, milk and a bunch of choclate. After that we were walking back home when it suddenly started raining, which was very unexpected. Luckily, we didn't live too far away, so we ran hom"
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0),
                scope: .paragraph,
                maximumUTF16Length: 800
            )
        )

        XCTAssertEqual(context.text, text)
        XCTAssertEqual(context.targetKind, .paragraph)
        XCTAssertEqual(context.leadingContext, "")
        XCTAssertFalse(context.completionIsAllowed)
    }

    func testDocumentScopeExtractsWholeFieldAndRejectsOversizedField() throws {
        let text = "First paragraph.\nSecond paragraph."
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0),
                scope: .document,
                maximumUTF16Length: 100
            )
        )

        XCTAssertEqual(context.text, text)
        XCTAssertEqual(context.targetKind, .document)
        XCTAssertNil(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: 0, length: 0),
                scope: .document,
                maximumUTF16Length: 10
            )
        )
    }

    func testBoundedParagraphDoesNotStartOrEndInsideAWord() throws {
        let text = Array(repeating: "alphabet", count: 80).joined(separator: " ")
        let source = text as NSString
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: source.length / 2, length: 0),
                scope: .paragraph,
                maximumUTF16Length: 120
            )
        )

        XCTAssertLessThanOrEqual(context.utf16Length, 120)
        if context.utf16Location > 0 {
            XCTAssertTrue(
                source.substring(
                    with: NSRange(location: context.utf16Location - 1, length: 1)
                ).allSatisfy(\.isWhitespace)
            )
        }
        if NSMaxRange(context.range) < source.length {
            XCTAssertTrue(
                source.substring(
                    with: NSRange(location: NSMaxRange(context.range), length: 1)
                ).allSatisfy(\.isWhitespace)
            )
        }
    }

    func testRejectsOversizedSelection() {
        XCTAssertNil(
            TextEditContextExtractor.extract(
                from: String(repeating: "a", count: 20),
                selectedRange: NSRange(location: 0, length: 20),
                maximumUTF16Length: 10
            )
        )
    }

    func testReplacementRequiresMatchingOriginalText() {
        let context = TextEditContext(text: "world", utf16Location: 6, utf16Length: 5)

        XCTAssertEqual(
            TextEditContextExtractor.replacing(
                context: context,
                in: "hello world",
                with: "there"
            ),
            "hello there"
        )
        XCTAssertNil(
            TextEditContextExtractor.replacing(
                context: context,
                in: "hello earth",
                with: "there"
            )
        )
    }

    func testUnicodeReplacementUsesUTF16Offsets() {
        let text = "Hello 👨‍👩‍👧‍👦 world"
        let range = (text as NSString).range(of: "world")
        let context = TextEditContext(
            text: "world",
            utf16Location: range.location,
            utf16Length: range.length
        )

        XCTAssertEqual(
            TextEditContextExtractor.replacing(
                context: context,
                in: text,
                with: "everyone"
            ),
            "Hello 👨‍👩‍👧‍👦 everyone"
        )
    }

    func testAllowsCompletionOnlyAtUnfinishedTargetEnd() throws {
        let unfinished = "I really apprecia"
        let allowed = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: unfinished,
                selectedRange: NSRange(location: (unfinished as NSString).length, length: 0)
            )
        )
        XCTAssertTrue(allowed.completionIsAllowed)

        let middle = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: unfinished,
                selectedRange: NSRange(location: 3, length: 0)
            )
        )
        XCTAssertFalse(middle.completionIsAllowed)

        let finished = "This is finished."
        let finishedContext = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: finished,
                selectedRange: NSRange(location: (finished as NSString).length, length: 0)
            )
        )
        XCTAssertFalse(finishedContext.completionIsAllowed)
    }

    func testAllowsCompletionAfterTrimmedTrailingWhitespace() throws {
        let text = "I think we should "
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0)
            )
        )

        XCTAssertEqual(context.text, "I think we should")
        XCTAssertTrue(context.completionIsAllowed)
    }

    func testSelectionNeverAllowsCompletion() throws {
        let text = "unfinished"
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: 0, length: (text as NSString).length)
            )
        )

        XCTAssertEqual(context.targetKind, .selection)
        XCTAssertFalse(context.completionIsAllowed)
    }

    func testSelectionTakesPriorityOverExplicitParagraphScope() throws {
        let text = "First sentence. Review only these words. Last sentence."
        let selection = (text as NSString).range(of: "only these words")
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: selection,
                scope: .paragraph
            )
        )

        XCTAssertEqual(context.text, "only these words")
        XCTAssertEqual(context.targetKind, .selection)
        XCTAssertEqual(context.utf16Location, selection.location)
        XCTAssertEqual(context.utf16Length, selection.length)
        XCTAssertEqual(context.leadingContext, "First sentence. Review")
        XCTAssertEqual(context.trailingContext, ". Last sentence.")
    }

    func testHonorsSmallerSurroundingContextLimit() throws {
        let text = "Before context. Target sentence here. After context."
        let caret = (text as NSString).range(of: "Target").location
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: caret, length: 0),
                maximumUTF16Length: 100,
                maximumSurroundingContextUTF16Length: 6
            )
        )

        XCTAssertLessThanOrEqual((context.leadingContext as NSString).length, 6)
        XCTAssertLessThanOrEqual((context.trailingContext as NSString).length, 6)
    }

    func testSentenceContextIncludesOnlyTheNearestAdjacentSentences() throws {
        let text = "First. Second. Third. Target sentence. Fourth. Fifth. Sixth."
        let caret = (text as NSString).range(of: "Target").location
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: NSRange(location: caret, length: 0),
                maximumSurroundingContextUTF16Length: 200
            )
        )

        XCTAssertEqual(context.leadingContext, "Third.")
        XCTAssertEqual(context.trailingContext, "Fourth.")
    }

    func testLongSelectionKeepsItsIndependentReadOnlyContextBudget() throws {
        let text = "Before. Selected. After."
        let selection = (text as NSString).range(of: "Selected")
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: text,
                selectedRange: selection,
                maximumUTF16Length: selection.length,
                maximumSurroundingContextUTF16Length: 100
            )
        )

        XCTAssertEqual(context.text, "Selected")
        XCTAssertEqual(context.leadingContext, "Before.")
        XCTAssertEqual(context.trailingContext, ". After.")
    }

    func testUntypedApplicationContextBecomesARelatedContentFragment() {
        let context = TextEditContext(
            text: "Draft",
            utf16Location: 4,
            utf16Length: 5,
            applicationContext: "Earlier conversation",
            leadingContext: "Before",
            trailingContext: "After"
        )

        XCTAssertEqual(context.applicationContext, "Earlier conversation")
        XCTAssertEqual(context.range, NSRange(location: 4, length: 5))
        XCTAssertEqual(
            context.applicationContextFragments,
            [.init(kind: .relatedContent, text: "Earlier conversation")]
        )
    }

    func testAddsStructuredApplicationContextWithoutChangingEditableRange() {
        let original = TextEditContext(
            text: "Draft",
            utf16Location: 4,
            utf16Length: 5
        )
        let fragments = [
            ReadOnlyContextFragment(kind: .fieldLabel, text: "Reply"),
            ReadOnlyContextFragment(
                kind: .relatedPrecedingContent,
                text: "The earlier message"
            )
        ]

        let enriched = original.withApplicationContext(fragments)

        XCTAssertEqual(enriched.applicationContext, "Reply\nThe earlier message")
        XCTAssertEqual(enriched.applicationContextFragments, fragments)
        XCTAssertEqual(enriched.range, original.range)
    }

    func testReplacesEditableTextWhilePreservingSurroundingContext() {
        let original = TextEditContext(
            text: "Draft",
            utf16Location: 4,
            utf16Length: 5,
            applicationContext: "Earlier conversation",
            leadingContext: "Before",
            trailingContext: "After",
            targetKind: .selection,
            completionIsAllowed: true
        )

        let revised = original.withEditableText("Revised 🙂")

        XCTAssertEqual(revised.text, "Revised 🙂")
        XCTAssertEqual(revised.utf16Location, original.utf16Location)
        XCTAssertEqual(revised.utf16Length, 10)
        XCTAssertEqual(revised.applicationContext, original.applicationContext)
        XCTAssertEqual(revised.leadingContext, original.leadingContext)
        XCTAssertEqual(revised.trailingContext, original.trailingContext)
        XCTAssertEqual(revised.targetKind, original.targetKind)
        XCTAssertEqual(revised.completionIsAllowed, original.completionIsAllowed)
    }
}
