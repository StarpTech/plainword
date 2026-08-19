import Foundation
@testable import PlainwordCore
import XCTest

final class WritingDiffTests: XCTestCase {
    func testTracksRemovedRangesInOriginalUTF16Coordinates() {
        let segments = WritingDiffPlanner.make(
            original: "I definately sent teh file.",
            replacement: "I definitely sent the file."
        )

        XCTAssertEqual(
            segments.filter { $0.kind == .removed }.map(\.originalUTF16Range),
            [
                NSRange(location: 2, length: 10),
                NSRange(location: 18, length: 3)
            ]
        )
        XCTAssertEqual(
            segments.filter { $0.kind == .removed }.map(\.text),
            ["definately", "teh"]
        )
    }

    func testInsertionUsesZeroLengthOriginalRange() {
        let segments = WritingDiffPlanner.make(
            original: "Hello world",
            replacement: "Hello, world"
        )

        let insertion = segments.first { $0.kind == .inserted }
        XCTAssertEqual(insertion?.text, ",")
        XCTAssertEqual(insertion?.originalUTF16Range, NSRange(location: 5, length: 0))
    }

    func testRangesRemainCorrectForEmoji() {
        let segments = WritingDiffPlanner.make(
            original: "🙂 teh",
            replacement: "🙂 the"
        )

        XCTAssertEqual(
            segments.first { $0.kind == .removed }?.originalUTF16Range,
            NSRange(location: 3, length: 3)
        )
    }

    func testMixedCorrectionsKeepMarkableRangesWhenPunctuationIsInserted() {
        let segments = WritingDiffPlanner.make(
            original: "It's defintlys great ot have you",
            replacement: "It's definitely great to have you."
        )

        XCTAssertEqual(
            segments.filter { $0.kind == .removed }.map(\.text),
            ["defintlys", "ot"]
        )
        XCTAssertEqual(
            segments.filter { $0.kind == .inserted }.map(\.text),
            ["definitely", "to", "."]
        )
    }
}
