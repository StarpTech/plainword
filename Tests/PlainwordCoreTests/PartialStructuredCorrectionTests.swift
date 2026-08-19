import XCTest
@testable import PlainwordCore

final class PartialStructuredCorrectionTests: XCTestCase {
    func testReadsTheTextReceivedSoFar() {
        XCTAssertEqual(
            PartialStructuredCorrection.correctedText(
                from: #"{"corrected_text":"Hello wor"#
            ),
            "Hello wor"
        )
    }

    func testReadsTheWholeValueOnceItIsClosed() {
        XCTAssertEqual(
            PartialStructuredCorrection.correctedText(
                from: #"{"corrected_text":"Hello world","classification":"correction"}"#
            ),
            "Hello world"
        )
    }

    func testReadsAValueThatFollowsAnotherMember() {
        XCTAssertEqual(
            PartialStructuredCorrection.correctedText(
                from: #"{"classification": "rewrite", "corrected_text" : "Half a sent"#
            ),
            "Half a sent"
        )
    }

    func testDecodesEscapes() {
        XCTAssertEqual(
            PartialStructuredCorrection.correctedText(
                from: #"{"corrected_text":"Line one\nSaid \"go\" é"#
            ),
            "Line one\nSaid \"go\" é"
        )
    }

    func testDropsAnEscapeThatIsStillArriving() {
        XCTAssertEqual(
            PartialStructuredCorrection.correctedText(from: #"{"corrected_text":"Done\"#),
            "Done"
        )
        XCTAssertEqual(
            PartialStructuredCorrection.correctedText(from: #"{"corrected_text":"Done\u00"#),
            "Done"
        )
    }

    func testWaitsForBothHalvesOfASurrogatePair() {
        XCTAssertEqual(
            PartialStructuredCorrection.correctedText(
                from: #"{"corrected_text":"Ship it \ud83d"#
            ),
            "Ship it "
        )
        XCTAssertEqual(
            PartialStructuredCorrection.correctedText(
                from: #"{"corrected_text":"Ship it 🚀"#
            ),
            "Ship it 🚀"
        )
    }

    func testRecoversFromAnUnescapedControlCharacter() {
        XCTAssertEqual(
            PartialStructuredCorrection.correctedText(
                from: "{\"corrected_text\":\"Line one\nLine two"
            ),
            "Line one\nLine two"
        )
    }

    func testReportsNothingBeforeTheValueStarts() {
        XCTAssertNil(PartialStructuredCorrection.correctedText(from: ""))
        XCTAssertNil(PartialStructuredCorrection.correctedText(from: #"{"corrected"#))
        XCTAssertNil(PartialStructuredCorrection.correctedText(from: #"{"corrected_text":"#))
        XCTAssertNil(PartialStructuredCorrection.correctedText(from: #"{"corrected_text":""#))
    }
}
