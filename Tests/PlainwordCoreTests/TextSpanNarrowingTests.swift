import Foundation
@testable import PlainwordCore
import XCTest

final class TextSpanNarrowingTests: XCTestCase {
    private let email = """
        Hi Bob,

        Thanks for you're help yesterday.

        Best,
        Dustin
        Head of Everything, Example Ltd
        """

    func testSignatureIsOutsideTheWrittenSpan() {
        let corrected = email.replacingOccurrences(of: "you're", with: "your")
        guard let span = TextSpanNarrowing.narrow(
            original: email,
            replacement: corrected
        ) else {
            return XCTFail("Expected a changed span")
        }

        XCTAssertEqual(span.originalText, "'re")
        XCTAssertEqual(span.replacement, "r")
        XCTAssertFalse(span.originalText.contains("Dustin"))
        XCTAssertFalse(span.originalText.contains(where: \.isNewline))
    }

    func testSpanAddressesTheOriginalText() {
        let corrected = email.replacingOccurrences(of: "Thanks", with: "Thank you")
        guard let span = TextSpanNarrowing.narrow(
            original: email,
            replacement: corrected
        ) else {
            return XCTFail("Expected a changed span")
        }

        let source = email as NSString
        XCTAssertEqual(source.substring(with: span.originalUTF16Range), span.originalText)
        XCTAssertEqual(
            source.replacingCharacters(in: span.originalUTF16Range, with: span.replacement),
            corrected
        )
    }

    func testWritingTheSpanReproducesACorrectionThatMergedParagraphs() {
        // The pairing the line planner needs is gone, so this is the write that runs.
        // It still has to leave the signature out of it.
        let corrected = """
        Hi Bob,

        Thanks for your help yesterday. It made the difference.

        Best,
        Dustin
        Head of Everything, Example Ltd
        """

        guard let span = TextSpanNarrowing.narrow(
            original: email,
            replacement: corrected
        ) else {
            return XCTFail("Expected a changed span")
        }

        XCTAssertFalse(span.originalText.contains("Dustin"))
        XCTAssertFalse(span.originalText.contains("Hi Bob"))
        XCTAssertEqual(
            (email as NSString).replacingCharacters(
                in: span.originalUTF16Range,
                with: span.replacement
            ),
            corrected
        )
    }

    func testPureInsertionHasAnEmptyOriginalSpan() {
        guard let span = TextSpanNarrowing.narrow(
            original: "Hello world",
            replacement: "Hello, world"
        ) else {
            return XCTFail("Expected a changed span")
        }

        XCTAssertEqual(span.originalUTF16Range, NSRange(location: 5, length: 0))
        XCTAssertEqual(span.originalText, "")
        XCTAssertEqual(span.replacement, ",")
    }

    func testPureDeletionHasAnEmptyReplacement() {
        guard let span = TextSpanNarrowing.narrow(
            original: "Thanks so so much",
            replacement: "Thanks so much"
        ) else {
            return XCTFail("Expected a changed span")
        }

        XCTAssertEqual(span.replacement, "")
        XCTAssertEqual(
            (("Thanks so so much") as NSString).replacingCharacters(
                in: span.originalUTF16Range,
                with: span.replacement
            ),
            "Thanks so much"
        )
    }

    func testSpanNeverSplitsACharacterBuiltFromSeveralUTF16Units() {
        let original = "Shipped 🚀🚀 today"
        let corrected = "Shipped 🚀 today"

        guard let span = TextSpanNarrowing.narrow(
            original: original,
            replacement: corrected
        ) else {
            return XCTFail("Expected a changed span")
        }

        let source = original as NSString
        XCTAssertEqual(
            source.rangeOfComposedCharacterSequences(for: span.originalUTF16Range),
            span.originalUTF16Range
        )
        XCTAssertEqual(
            source.replacingCharacters(in: span.originalUTF16Range, with: span.replacement),
            corrected
        )
    }

    func testUnchangedTextHasNoSpan() {
        XCTAssertNil(TextSpanNarrowing.narrow(original: email, replacement: email))
    }

    func testNarrowedSpanStillPlansLineByLine() {
        let corrected = """
        Hi Bob,

        Thank you for your help yesterday.

        Best regards,
        Dustin
        Head of Everything, Example Ltd
        """

        guard let span = TextSpanNarrowing.narrow(
            original: email,
            replacement: corrected
        ) else {
            return XCTFail("Expected a changed span")
        }
        guard let edits = LineSegmentedEditPlanner.plan(
            original: span.originalText,
            replacement: span.replacement
        ) else {
            return XCTFail("Expected the narrowed span to plan line by line")
        }

        // Offsets are relative to the span, so they only address the document once the
        // span's own location is added back.
        var result = span.originalText as NSString
        for edit in edits.reversed() {
            result = result.replacingCharacters(
                in: edit.originalUTF16Range,
                with: edit.replacement
            ) as NSString
        }
        XCTAssertEqual(result as String, span.replacement)
        XCTAssertEqual(
            (email as NSString).replacingCharacters(
                in: span.originalUTF16Range,
                with: result as String
            ),
            corrected
        )
    }
}
