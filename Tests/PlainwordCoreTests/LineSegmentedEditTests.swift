import Foundation
@testable import PlainwordCore
import XCTest

final class LineSegmentedEditTests: XCTestCase {
    private let email = """
        Hi Bob,

        Thanks for you're help yesterday.

        Best,
        Dustin
        """

    func testWritesOnlyTheLinesThatChanged() {
        let corrected = """
        Hi Bob,

        Thanks for your help yesterday.

        Best,
        Dustin
        """

        let edits = LineSegmentedEditPlanner.plan(original: email, replacement: corrected)

        XCTAssertEqual(edits?.count, 1)
        XCTAssertEqual(edits?.first?.originalText, "Thanks for you're help yesterday.")
        XCTAssertEqual(edits?.first?.replacement, "Thanks for your help yesterday.")
    }

    func testEditRangeAddressesTheLineAloneWithoutItsBreak() {
        let corrected = email.replacingOccurrences(of: "you're", with: "your")
        guard let edit = LineSegmentedEditPlanner.plan(
            original: email,
            replacement: corrected
        )?.first else {
            return XCTFail("Expected a plan for a single changed line")
        }

        let source = email as NSString
        XCTAssertEqual(source.substring(with: edit.originalUTF16Range), edit.originalText)
        XCTAssertFalse(edit.originalText.contains(where: \.isNewline))
        XCTAssertFalse(edit.replacement.contains(where: \.isNewline))
    }

    func testPlannedWritesReproduceTheCorrection() {
        let corrected = """
        Hi Bob,

        Thanks for your help yesterday.

        Best regards,
        Dustin
        """

        guard let edits = LineSegmentedEditPlanner.plan(
            original: email,
            replacement: corrected
        ) else {
            return XCTFail("Expected a plan for two changed lines")
        }
        XCTAssertEqual(edits.count, 2)

        // Applied last line first, exactly as the writes are ordered against the host.
        var result = email as NSString
        for edit in edits.reversed() {
            result = result.replacingCharacters(
                in: edit.originalUTF16Range,
                with: edit.replacement
            ) as NSString
        }
        XCTAssertEqual(result as String, corrected)
    }

    func testBlankLineBecomingContentIsStillPlannable() {
        let original = "First paragraph.\n\nSecond paragraph."
        let corrected = "First paragraph.\nA new middle line.\nSecond paragraph."

        // The break count is unchanged, so each line still has its counterpart.
        let edits = LineSegmentedEditPlanner.plan(original: original, replacement: corrected)

        XCTAssertEqual(edits?.count, 1)
        XCTAssertEqual(edits?.first?.originalText, "")
        XCTAssertEqual(edits?.first?.replacement, "A new middle line.")
        XCTAssertEqual(edits?.first?.originalUTF16Range, NSRange(location: 17, length: 0))
    }

    func testMergedParagraphsAreNotPlannable() {
        XCTAssertNil(
            LineSegmentedEditPlanner.plan(
                original: "First paragraph.\n\nSecond paragraph.",
                replacement: "First paragraph. Second paragraph."
            )
        )
    }

    func testSplitParagraphIsNotPlannable() {
        XCTAssertNil(
            LineSegmentedEditPlanner.plan(
                original: "First sentence. Second sentence.",
                replacement: "First sentence.\n\nSecond sentence."
            )
        )
    }

    func testRespelledLineBreakIsNotPlannable() {
        XCTAssertNil(
            LineSegmentedEditPlanner.plan(
                original: "First line.\r\nSecond line.",
                replacement: "First line.\nSecond line."
            )
        )
    }

    func testCarriageReturnPairIsOneBreak() {
        let edits = LineSegmentedEditPlanner.plan(
            original: "First line.\r\nsecond line.",
            replacement: "First line.\r\nSecond line."
        )

        XCTAssertEqual(edits?.count, 1)
        XCTAssertEqual(edits?.first?.originalUTF16Range, NSRange(location: 13, length: 12))
    }

    func testUnchangedTextHasNothingToWrite() {
        XCTAssertNil(LineSegmentedEditPlanner.plan(original: email, replacement: email))
    }

    func testSingleLineTargetIsPlannedAsOneWrite() {
        let edits = LineSegmentedEditPlanner.plan(
            original: "Thanks for you're help.",
            replacement: "Thanks for your help."
        )

        XCTAssertEqual(edits?.count, 1)
        XCTAssertEqual(edits?.first?.originalUTF16Range, NSRange(location: 0, length: 23))
    }

    func testCorrectionTouchingEveryLineOfALongTextIsNotPlannable() {
        let lineCount = LineSegmentedEditPlanner.maximumSegmentCount + 1
        let original = (0..<lineCount).map { "line \($0) is here" }.joined(separator: "\n")
        let corrected = (0..<lineCount).map { "Line \($0) is here." }.joined(separator: "\n")

        XCTAssertNil(
            LineSegmentedEditPlanner.plan(original: original, replacement: corrected)
        )
    }
}
