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

    func testSegmentsReconstructBothInputsAndPartitionOriginalUTF16Range() {
        let examples: [(original: String, replacement: String)] = [
            ("", ""),
            ("", "Hello 👋"),
            ("Delete this", ""),
            ("unchanged", "unchanged"),
            ("Cafe\u{301} noir", "Café noir."),
            ("🙂 teh  file", "🙂 the file!"),
            ("It's fine\nReally", "It’s fine.\nReally!"),
            ("中文。测试", "中文测试！")
        ]

        for example in examples {
            let segments = WritingDiffPlanner.make(
                original: example.original,
                replacement: example.replacement
            )

            XCTAssertEqual(
                segments
                    .filter { $0.kind != .inserted }
                    .map(\.text)
                    .joined(),
                example.original,
                "Original reconstruction failed for \(example)"
            )
            XCTAssertEqual(
                segments
                    .filter { $0.kind != .removed }
                    .map(\.text)
                    .joined(),
                example.replacement,
                "Replacement reconstruction failed for \(example)"
            )

            var expectedOffset = 0
            for segment in segments {
                XCTAssertEqual(
                    segment.originalUTF16Range.location,
                    expectedOffset,
                    "Non-contiguous original ranges for \(example)"
                )
                let expectedLength = segment.kind == .inserted
                    ? 0
                    : (segment.text as NSString).length
                XCTAssertEqual(segment.originalUTF16Range.length, expectedLength)
                expectedOffset += expectedLength
            }
            XCTAssertEqual(expectedOffset, (example.original as NSString).length)
        }
    }
}
