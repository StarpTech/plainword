import Foundation
@testable import PlainwordCore
import XCTest

final class SignatureBoundaryTests: XCTestCase {
    private func signature(in text: String) -> String? {
        SignatureBoundary.location(in: text).map {
            (text as NSString).substring(from: $0)
        }
    }

    func testConventionalDelimiterStartsTheSignature() {
        let email = """
        Hi Bob,

        Thanks for your help yesterday.

        --
        Dustin
        Head of Everything
        """

        XCTAssertEqual(signature(in: email), "--\nDustin\nHead of Everything")
    }

    func testTrailingBlockWithAnEmailAddressIsASignature() {
        let email = """
        Hi Bob,

        Thanks for your help yesterday.

        Best,
        Dustin
        dustin@example.com
        """

        XCTAssertEqual(signature(in: email), "Best,\nDustin\ndustin@example.com")
    }

    func testTrailingBlockWithAPhoneNumberIsASignature() {
        let email = """
        Speak soon.

        Dustin Example
        Example Ltd
        +44 20 7123 4567
        """

        XCTAssertEqual(signature(in: email), "Dustin Example\nExample Ltd\n+44 20 7123 4567")
    }

    func testTrailingBlockWithAWebAddressIsASignature() {
        let email = """
        Have a look when you can.

        Dustin
        www.example.com
        """

        XCTAssertEqual(signature(in: email), "Dustin\nwww.example.com")
    }

    // MARK: - What must not be mistaken for one

    func testPlainSignOffIsLeftInTheMessage() {
        // No contact detail, so nothing here is worth the risk of cutting it out.
        let email = """
        Hi Bob,

        Thanks for your help yesterday.

        Best,
        Dustin
        """

        XCTAssertNil(SignatureBoundary.location(in: email))
    }

    func testClosingParagraphMentioningALinkIsNotCutOutMidMessage() {
        let email = """
        Hi Bob,

        The document is at https://example.com/report when you have a minute.

        Could you read it before Thursday?
        """

        XCTAssertNil(SignatureBoundary.location(in: email))
    }

    func testALongTrailingBlockIsNotASignature() {
        let email = """
        Hi Bob,

        Here is where we are. Call me on +44 20 7123 4567 if any of this is wrong,
        because the numbers moved twice this week and the second revision is the one
        the board saw. The forecast is unchanged, the headcount is not, and the
        timeline now has two weeks in it that nobody has accounted for yet, which is
        the part I would like your opinion on before Thursday. I have attached the
        spreadsheet as it stood on Monday, before any of the revisions landed.
        """

        XCTAssertNil(SignatureBoundary.location(in: email))
    }

    func testAWholeMessageThatIsOnlyASignatureIsNotExcluded() {
        XCTAssertNil(SignatureBoundary.location(in: "Dustin\ndustin@example.com"))
    }

    func testDelimiterWithAWholeMessageBelowItIsIgnored() {
        let email = """
        --
        This is not a signature, it is the whole message, and it runs on for line
        after line after line, which a signature does not do, so the delimiter above
        cannot be what it looks like. Here is another line. And one more. And a last
        one, to be sure.
        """

        XCTAssertNil(SignatureBoundary.location(in: email))
    }

    func testEmptyTextHasNoSignature() {
        XCTAssertNil(SignatureBoundary.location(in: ""))
    }

    // MARK: - What the extractor does with it

    func testSignatureIsOutsideTheEditTarget() throws {
        let email = """
        Hi Bob,

        Thanks for you're help yesterday.

        Best,
        Dustin
        dustin@example.com
        """
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: email,
                selectedRange: NSRange(location: 0, length: 0),
                scope: .document
            )
        )

        XCTAssertFalse(context.text.contains("dustin@example.com"))
        XCTAssertTrue(context.text.contains("Thanks for you're help yesterday."))
        // Not sent as context either. A correction has no use for it, and every part of
        // the request it is absent from is one it cannot be edited from.
        XCTAssertFalse(context.trailingContext.contains("dustin@example.com"))
        XCTAssertFalse(context.leadingContext.contains("dustin@example.com"))
    }

    func testCaretInsideTheSignatureStillEditsIt() throws {
        let email = """
        Hi Bob,

        Thanks for your help.

        Best,
        Dustin
        dustin@example.com
        """
        let caret = (email as NSString).range(of: "Dustin\ndustin").location
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: email,
                selectedRange: NSRange(location: caret, length: 0),
                scope: .document
            )
        )

        XCTAssertTrue(context.text.contains("dustin@example.com"))
    }

    func testAnExplicitSelectionIsNeverTrimmed() throws {
        let email = """
        Thanks for your help.

        Dustin
        dustin@example.com
        """
        let selection = NSRange(location: 0, length: (email as NSString).length)
        let context = try XCTUnwrap(
            TextEditContextExtractor.extract(
                from: email,
                selectedRange: selection,
                scope: .document
            )
        )

        XCTAssertTrue(context.text.contains("dustin@example.com"))
    }
}
