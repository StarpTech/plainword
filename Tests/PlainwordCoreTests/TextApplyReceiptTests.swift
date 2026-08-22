import Foundation
@testable import PlainwordCore
import XCTest

final class TextApplyReceiptTests: XCTestCase {
    private func receipt(
        targetUTF16Length: Int = 400,
        changedRange: NSRange = NSRange(location: 41, length: 27),
        plannedWrites: Int = 2,
        isWebArea: Bool = true,
        outcome: TextApplyReceipt.Outcome
    ) -> TextApplyReceipt {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        return TextApplyReceipt(
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(0.25),
            applicationName: "Google Chrome",
            targetKind: "document",
            targetUTF16Length: targetUTF16Length,
            changedRange: changedRange,
            plannedWrites: plannedWrites,
            isWebArea: isWebArea,
            outcome: outcome
        )
    }

    func testSummarySaysWhatWasWrittenWhereAndHow() {
        let line = receipt(outcome: .applied(.perLine)).summary

        XCTAssertEqual(
            line,
            "document, 400 chars · 2 writes · chars 41–68 · web page · applied line by line"
        )
    }

    func testAWholeFieldWriteIsVisibleInTheSummary() {
        // This is the shape the signature damage had. It should be readable at a glance.
        let line = receipt(
            changedRange: NSRange(location: 0, length: 400),
            plannedWrites: 1,
            outcome: .applied(.wholeValue)
        ).summary

        XCTAssertTrue(line.contains("1 write"))
        XCTAssertTrue(line.contains("chars 0–400"))
        XCTAssertTrue(line.contains("applied whole field"))
    }

    func testAPartWayRefusalReadsAsAFailure() {
        let subject = receipt(
            outcome: .partiallyApplied(landedWrites: 1, restoredWrites: 0)
        )

        XCTAssertTrue(subject.isFailure)
        XCTAssertTrue(subject.summary.contains("1 landed"))
        XCTAssertTrue(subject.summary.contains("0 put back"))
    }

    func testARestoredRefusalIsNotAFailure() {
        // The field is as the author left it, so this is noise in a failures filter.
        XCTAssertFalse(receipt(outcome: .restored(writes: 2)).isFailure)
        XCTAssertEqual(
            receipt(outcome: .restored(writes: 2)).outcomeDescription,
            "refused, 2 put back"
        )
        XCTAssertEqual(
            receipt(outcome: .restored(writes: 0)).outcomeDescription,
            "refused, field untouched"
        )
    }

    func testChangedShareReportsHowMuchOfTheFieldWasTouched() {
        XCTAssertEqual(
            receipt(
                targetUTF16Length: 400,
                changedRange: NSRange(location: 0, length: 100),
                outcome: .applied(.span)
            ).changedShare,
            0.25,
            accuracy: 0.0001
        )
    }

    func testChangedShareOfAnEmptyTargetIsNotUndefined() {
        XCTAssertEqual(
            receipt(
                targetUTF16Length: 0,
                changedRange: NSRange(location: 0, length: 0),
                outcome: .unchanged
            ).changedShare,
            0
        )
    }
}
