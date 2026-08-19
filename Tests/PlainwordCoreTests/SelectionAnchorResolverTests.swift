import Foundation
import CoreGraphics
@testable import PlainwordCore
import XCTest

final class SelectionAnchorResolverTests: XCTestCase {
    private let start = CGRect(x: 100, y: 500, width: 2, height: 20)
    private let end = CGRect(x: 420, y: 420, width: 2, height: 20)

    func testUsesEndForForwardMouseSelection() {
        XCTAssertEqual(
            SelectionAnchorResolver.preferred(
                start: start,
                end: end,
                pointer: CGPoint(x: 424, y: 430)
            ),
            end
        )
    }

    func testUsesStartForBackwardMouseSelection() {
        XCTAssertEqual(
            SelectionAnchorResolver.preferred(
                start: start,
                end: end,
                pointer: CGPoint(x: 98, y: 510)
            ),
            start
        )
    }

    func testKeepsLogicalEndWhenPointerIsUnrelated() {
        XCTAssertEqual(
            SelectionAnchorResolver.preferred(
                start: start,
                end: end,
                pointer: CGPoint(x: 900, y: 900)
            ),
            end
        )
    }

    func testUsesPointerInsideEditorWhenEndpointGeometryIsUnavailable() {
        XCTAssertEqual(
            SelectionAnchorResolver.pointerFallback(
                pointer: CGPoint(x: 340, y: 240),
                inside: CGRect(x: 100, y: 100, width: 600, height: 400)
            ),
            CGRect(x: 340, y: 240, width: 2, height: 18)
        )
    }

    func testRejectsPointerOutsideEditor() {
        XCTAssertNil(
            SelectionAnchorResolver.pointerFallback(
                pointer: CGPoint(x: 900, y: 700),
                inside: CGRect(x: 100, y: 100, width: 600, height: 400)
            )
        )
    }
}
