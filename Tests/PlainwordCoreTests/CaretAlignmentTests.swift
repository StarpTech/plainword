import Foundation
@testable import PlainwordCore
import XCTest

final class CaretAlignmentTests: XCTestCase {
    private let note = """
        The delivery window moved to Thursday, so the crew will start on the north wall \
        and work back towards the yard.

        Regards,
        Sam
        """

    private var paragraphEnd: Int {
        (note as NSString).range(of: "the yard.").location + 9
    }

    private var signatureStart: Int {
        (note as NSString).range(of: "Regards,").location
    }

    func testCarriesADownstreamCaretBackToTheParagraphItEnds() {
        XCTAssertEqual(
            CaretAlignment.resolved(
                reported: signatureStart,
                lineBeforeCaret: "and work back towards the yard.",
                in: note
            ),
            paragraphEnd
        )
    }

    func testKeepsACaretThatReallyIsAtTheStartOfAParagraph() {
        XCTAssertEqual(
            CaretAlignment.resolved(
                reported: signatureStart,
                lineBeforeCaret: "",
                in: note
            ),
            signatureStart
        )
    }

    func testUsesOnlyTheLineTheCaretIsOn() {
        // A probe that overran into the paragraph above still resolves, and does so
        // without having to spell the blank line between them the same way.
        XCTAssertEqual(
            CaretAlignment.resolved(
                reported: signatureStart,
                lineBeforeCaret: "on the north wall\ntowards the yard.",
                in: note
            ),
            paragraphEnd
        )
    }

    func testKeepsACaretThatIsNotAtTheStartOfALine() {
        let midParagraph = paragraphEnd - 4
        XCTAssertEqual(
            CaretAlignment.resolved(
                reported: midParagraph,
                lineBeforeCaret: "and work back towards the y",
                in: note
            ),
            midParagraph
        )
    }

    func testKeepsACaretWhoseLineIsNotInTheCapturedText() {
        XCTAssertEqual(
            CaretAlignment.resolved(
                reported: signatureStart,
                lineBeforeCaret: "writing this document does not contain",
                in: note
            ),
            signatureStart
        )
    }

    func testWillNotCarryACaretAcrossWriting() {
        // "Reg" matches, but reaching the reported offset from it would skip a line of
        // the author's own text rather than a paragraph break.
        let afterSignature = (note as NSString).range(of: "Sam").location
        XCTAssertEqual(
            CaretAlignment.resolved(
                reported: afterSignature,
                lineBeforeCaret: "Reg",
                in: note
            ),
            afterSignature
        )
    }

    func testWillNotCarryACaretFurtherThanTheAllowance() {
        XCTAssertEqual(
            CaretAlignment.resolved(
                reported: signatureStart,
                lineBeforeCaret: "the yard.",
                in: note,
                maximumSkippedLineBreaks: 0
            ),
            signatureStart
        )
    }

    func testCrossesASingleParagraphBreak() {
        let text = "First paragraph.\nSecond paragraph."
        XCTAssertEqual(
            CaretAlignment.resolved(
                reported: 17,
                lineBeforeCaret: "First paragraph.",
                in: text
            ),
            16
        )
    }

    func testReportsWhereALineStarts() {
        XCTAssertFalse(CaretAlignment.isAtLineStart(0, in: note))
        XCTAssertFalse(CaretAlignment.isAtLineStart(paragraphEnd, in: note))
        XCTAssertTrue(CaretAlignment.isAtLineStart(signatureStart, in: note))
        XCTAssertFalse(CaretAlignment.isAtLineStart(9_999, in: note))
    }
}
