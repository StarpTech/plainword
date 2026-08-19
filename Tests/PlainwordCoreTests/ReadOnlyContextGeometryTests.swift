import CoreGraphics
import Foundation
import XCTest
@testable import PlainwordCore

/// Frames use AppKit screen coordinates: `y` grows upward, so a larger `maxY` is higher
/// on screen. The focused field below sits at y 500...520.
final class ReadOnlyContextGeometryTests: XCTestCase {
    private let focusedFrame = CGRect(x: 100, y: 500, width: 400, height: 20)

    private func candidate(
        _ text: String,
        frame: CGRect,
        isHeading: Bool = false,
        ancestorDistance: Int = 0
    ) -> ReadOnlyContextCandidate? {
        ReadOnlyContextGeometry.candidate(
            text: text,
            isHeading: isHeading,
            frame: frame,
            focusedFrame: focusedFrame,
            ancestorDistance: ancestorDistance
        )
    }

    // MARK: - Classification

    func testContentAboveTheFieldBecomesPrecedingContent() throws {
        let result = try XCTUnwrap(
            candidate(
                "The build finished a few minutes ago.",
                frame: CGRect(x: 100, y: 540, width: 400, height: 18)
            )
        )
        XCTAssertEqual(result.kind, .relatedPrecedingContent)
    }

    func testContentJustBelowTheFieldBecomesAFieldDescription() throws {
        let result = try XCTUnwrap(
            candidate("Press Return to send", frame: CGRect(x: 100, y: 470, width: 400, height: 14))
        )
        XCTAssertEqual(result.kind, .fieldDescription)
    }

    func testTextBesideTheFieldBecomesAFieldLabel() throws {
        let result = try XCTUnwrap(
            candidate("Subject", frame: CGRect(x: 20, y: 502, width: 60, height: 16))
        )
        XCTAssertEqual(result.kind, .fieldLabel)
    }

    func testHeadingAboveTheFieldBecomesADocumentTitle() throws {
        let result = try XCTUnwrap(
            candidate(
                "Project Atlas",
                frame: CGRect(x: 100, y: 560, width: 400, height: 24),
                isHeading: true
            )
        )
        XCTAssertEqual(result.kind, .documentTitle)
    }

    // MARK: - Rejection

    func testRejectsContentTooFarBelowTheField() {
        XCTAssertNil(
            candidate("Unrelated footer", frame: CGRect(x: 100, y: 380, width: 400, height: 14))
        )
    }

    func testRejectsContentBeyondTheTranscriptWindowAbove() {
        XCTAssertNil(
            candidate("Ancient message", frame: CGRect(x: 100, y: 1_600, width: 400, height: 18))
        )
    }

    func testRejectsContentInAnAdjacentColumn() {
        XCTAssertNil(
            candidate("Sidebar item", frame: CGRect(x: 900, y: 540, width: 200, height: 18))
        )
    }

    func testRejectsTextTooShortToCarryMeaning() {
        XCTAssertNil(candidate("ok", frame: CGRect(x: 100, y: 540, width: 400, height: 18)))
    }

    func testRejectsAnEmptyFrame() {
        XCTAssertNil(candidate("Invisible", frame: .zero))
    }

    // MARK: - Relevance

    func testNearerContentAboveOutranksFartherContentAbove() throws {
        let near = try XCTUnwrap(
            candidate("The nearest message here", frame: CGRect(x: 100, y: 540, width: 400, height: 18))
        )
        let far = try XCTUnwrap(
            candidate("The oldest message here", frame: CGRect(x: 100, y: 1_300, width: 400, height: 18))
        )
        XCTAssertGreaterThan(near.relevance, far.relevance)
    }

    func testDistantAncestryIsPenalised() throws {
        let frame = CGRect(x: 100, y: 540, width: 400, height: 18)
        let near = try XCTUnwrap(candidate("A nearby message", frame: frame, ancestorDistance: 0))
        let far = try XCTUnwrap(candidate("A nearby message", frame: frame, ancestorDistance: 6))
        XCTAssertGreaterThan(near.relevance, far.relevance)
    }

    // MARK: - Reading order

    func testReadingOrderFollowsTheScreenTopDownThenLeftToRight() {
        let top = ReadOnlyContextGeometry.readingOrder(for: CGRect(x: 100, y: 900, width: 100, height: 20))
        let middleLeft = ReadOnlyContextGeometry.readingOrder(for: CGRect(x: 100, y: 600, width: 100, height: 20))
        let middleRight = ReadOnlyContextGeometry.readingOrder(for: CGRect(x: 400, y: 600, width: 100, height: 20))
        let bottom = ReadOnlyContextGeometry.readingOrder(for: CGRect(x: 100, y: 200, width: 100, height: 20))

        XCTAssertLessThan(top, middleLeft)
        XCTAssertLessThan(middleLeft, middleRight)
        XCTAssertLessThan(middleRight, bottom)
    }

    func testExplicitRelationshipsAlwaysReadBeforeInferredGeometry() {
        let highestOnAnyPlausibleScreen = ReadOnlyContextGeometry.readingOrder(
            for: CGRect(x: 0, y: 500_000, width: 100, height: 20)
        )
        XCTAssertLessThan(
            ReadOnlyContextGeometry.metadataReadingOrder,
            highestOnAnyPlausibleScreen
        )
    }

    // MARK: - Traversal priority

    func testProximityPrefersContentDirectlyAboveOverContentToTheSide() {
        let above = ReadOnlyContextGeometry.proximity(
            of: CGRect(x: 100, y: 560, width: 400, height: 18),
            to: focusedFrame
        )
        let beside = ReadOnlyContextGeometry.proximity(
            of: CGRect(x: 540, y: 505, width: 100, height: 18),
            to: focusedFrame
        )
        XCTAssertLessThan(above, beside)
    }

    func testProximityIsZeroForAnOverlappingFrame() {
        XCTAssertEqual(
            ReadOnlyContextGeometry.proximity(
                of: CGRect(x: 120, y: 505, width: 100, height: 10),
                to: focusedFrame
            ),
            0
        )
    }

    // MARK: - Search bounds and budget

    func testSearchBoundsReachTheTranscriptAboveAndTheCaptionBelow() {
        let bounds = ReadOnlyContextGeometry.searchBounds(around: focusedFrame, clippedTo: nil)
        XCTAssertTrue(bounds.contains(CGPoint(x: 300, y: 520 + ReadOnlyContextGeometry.maximumAboveGap - 1)))
        XCTAssertFalse(bounds.contains(CGPoint(x: 300, y: 520 + ReadOnlyContextGeometry.maximumAboveGap + 1)))
        XCTAssertTrue(bounds.contains(CGPoint(x: 300, y: 500 - ReadOnlyContextGeometry.maximumBelowGap)))
    }

    func testSearchBoundsAreClippedToTheEnclosingViewport() {
        let viewport = CGRect(x: 150, y: 480, width: 200, height: 200)
        let bounds = ReadOnlyContextGeometry.searchBounds(around: focusedFrame, clippedTo: viewport)
        XCTAssertEqual(bounds, bounds.intersection(viewport))
    }

    func testShortTargetsEarnAWiderContextBudgetThanLongOnes() {
        XCTAssertGreaterThan(
            ReadOnlyContextGeometry.budgetUTF16Length(targetUTF16Length: 40),
            ReadOnlyContextGeometry.budgetUTF16Length(targetUTF16Length: 1_200)
        )
        XCTAssertLessThanOrEqual(
            ReadOnlyContextGeometry.budgetUTF16Length(targetUTF16Length: 1),
            ReadOnlyContextGeometry.maximumBudgetUTF16Length
        )
    }
}
