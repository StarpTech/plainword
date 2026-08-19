import Foundation
import XCTest
@testable import PlainwordCore

final class ReadOnlyContextDigestTests: XCTestCase {
    func testFragmentOrderDoesNotChangeTheDigest() {
        let label = ReadOnlyContextFragment(kind: .fieldLabel, text: "Reply")
        let content = ReadOnlyContextFragment(
            kind: .relatedPrecedingContent,
            text: "Atlas shipped yesterday."
        )

        XCTAssertEqual(
            ReadOnlyContextDigest.value(for: [label, content]),
            ReadOnlyContextDigest.value(for: [content, label])
        )
    }

    func testKindIsPartOfTheDigest() {
        XCTAssertNotEqual(
            ReadOnlyContextDigest.value(for: [.init(kind: .documentTitle, text: "Atlas")]),
            ReadOnlyContextDigest.value(for: [.init(kind: .fieldLabel, text: "Atlas")])
        )
    }

    func testAnElisionMarkerDoesNotChangeTheDigest() {
        XCTAssertEqual(
            ReadOnlyContextDigest.value(for: [
                .init(kind: .relatedPrecedingContent, text: "Atlas shipped yesterday.")
            ]),
            ReadOnlyContextDigest.value(for: [
                .init(
                    kind: .relatedPrecedingContent,
                    text: "\(ReadOnlyContextRanker.elisionMarker) Atlas shipped yesterday."
                )
            ])
        )
    }

    func testDroppedFragmentChangesTheDigest() {
        XCTAssertNotEqual(
            ReadOnlyContextDigest.value(for: [
                .init(kind: .fieldLabel, text: "Reply"),
                .init(kind: .relatedPrecedingContent, text: "Atlas shipped yesterday.")
            ]),
            ReadOnlyContextDigest.value(for: [.init(kind: .fieldLabel, text: "Reply")])
        )
    }

    func testWhitespaceCaseAndPunctuationAreFoldedAway() {
        XCTAssertEqual(
            ReadOnlyContextDigest.value(for: "The introduction is fine.", retaining: .end),
            ReadOnlyContextDigest.value(for: "the  Introduction   is fine!", retaining: .end)
        )
    }

    func testTextWithoutLettersOrNumbersDigestsToNothing() {
        XCTAssertEqual(ReadOnlyContextDigest.value(for: "  —  ", retaining: .end), "")
        XCTAssertEqual(ReadOnlyContextDigest.value(for: "", retaining: .start), "")
    }

    /// Preceding context is identified by the end nearest the target, so a passage that
    /// grows away from the target keeps its identity.
    func testPrecedingContextKeepsTheEndNearestTheTarget() {
        let shared = String(repeating: "near ", count: 40)
        XCTAssertEqual(
            ReadOnlyContextDigest.value(for: "an older opening. " + shared, retaining: .end),
            ReadOnlyContextDigest.value(for: "a rewritten opening. " + shared, retaining: .end)
        )
    }

    /// Following context is identified by its start, for the same reason mirrored.
    func testFollowingContextKeepsTheStartNearestTheTarget() {
        let shared = String(repeating: "near ", count: 40)
        XCTAssertEqual(
            ReadOnlyContextDigest.value(for: shared + " a later ending.", retaining: .start),
            ReadOnlyContextDigest.value(for: shared + " a different ending.", retaining: .start)
        )
    }

    func testAChangeAdjacentToTheTargetStillChangesTheDigest() {
        let shared = String(repeating: "far ", count: 40)
        XCTAssertNotEqual(
            ReadOnlyContextDigest.value(for: shared + " the nearest words.", retaining: .end),
            ReadOnlyContextDigest.value(for: shared + " entirely other words.", retaining: .end)
        )
    }
}
