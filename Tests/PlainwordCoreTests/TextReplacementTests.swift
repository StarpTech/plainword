import Foundation
@testable import PlainwordCore
import XCTest

/// What these cover is the arithmetic that used to live inside the accessibility client,
/// where nothing could reach it: which ranges a correction writes, in which order, and
/// what each write expects to find. A host is stood in for by a recorder, so a refusal
/// is something a test can ask for.
final class TextReplacementTests: XCTestCase {
    /// A composer holding a greeting, a body, and a signature, captured whole.
    private let composer = """
        Hi Bob,

        Thanks for you're help yesterday.

        Best,
        Dustin
        dustin@example.com
        """

    private let twoLineCorrection = """
        Hi Bob,

        Thanks for your help yesterday.

        Best regards,
        Dustin
        dustin@example.com
        """

    private func plan(
        correcting replacement: String,
        in capturedText: String? = nil,
        capturedLocation: Int = 0
    ) -> TextReplacementPlan? {
        let captured = capturedText ?? composer
        return TextReplacementPlanner.plan(
            capturedText: captured,
            capturedLocation: capturedLocation,
            targetLocation: capturedLocation,
            targetText: captured,
            replacement: replacement
        )
    }

    // MARK: - What a write covers

    func testSignatureIsNeverInsideAWrittenRange() throws {
        let corrected = composer.replacingOccurrences(of: "you're", with: "your")
        let plan = try XCTUnwrap(plan(correcting: corrected))
        let source = composer as NSString

        for write in plan.writes {
            let covered = source.substring(with: write.documentRange)
            XCTAssertFalse(covered.contains("dustin@example.com"))
            XCTAssertFalse(covered.contains("Dustin"))
            XCTAssertFalse(covered.contains("Hi Bob"))
        }
    }

    func testWriteRangesAreDocumentOffsetsNotCapturedOffsets() throws {
        // The captured window starts part-way into the document, which is what a
        // sentence-scoped capture of a long field looks like.
        let corrected = "Thanks for your help."
        let plan = try XCTUnwrap(
            TextReplacementPlanner.plan(
                capturedText: "Thanks for you're help.",
                capturedLocation: 400,
                targetLocation: 400,
                targetText: "Thanks for you're help.",
                replacement: corrected
            )
        )

        let write = try XCTUnwrap(plan.writes.first)
        XCTAssertEqual(write.documentRange, NSRange(location: 414, length: 3))
        XCTAssertEqual(write.originalText, "'re")
        XCTAssertEqual(write.replacement, "r")
        XCTAssertEqual(write.expectedCapturedRange.location, 400)
    }

    func testTargetSittingInsideALargerCaptureIsAddressedCorrectly() throws {
        let captured = "Header text.\n\nThanks for you're help.\n\nFooter text."
        let target = "Thanks for you're help."
        let targetLocation = (captured as NSString).range(of: target).location
        let plan = try XCTUnwrap(
            TextReplacementPlanner.plan(
                capturedText: captured,
                capturedLocation: 0,
                targetLocation: targetLocation,
                targetText: target,
                replacement: "Thanks for your help."
            )
        )

        let write = try XCTUnwrap(plan.writes.first)
        XCTAssertEqual(
            (captured as NSString).substring(with: write.documentRange),
            write.originalText
        )
        XCTAssertEqual(plan.updatedCapturedText, captured.replacingOccurrences(
            of: "you're",
            with: "your"
        ))
    }

    // MARK: - Order and expectations

    func testMultipleLinesAreWrittenLastFirst() throws {
        let corrected = """
        Hi Bob,

        Thanks for your help yesterday.

        Best regards,
        Dustin
        dustin@example.com
        """
        let plan = try XCTUnwrap(plan(correcting: corrected))

        XCTAssertEqual(plan.writes.count, 2)
        XCTAssertGreaterThan(
            plan.writes[0].documentRange.location,
            plan.writes[1].documentRange.location
        )
        // Narrowing has already run, so each line is written from its first changed
        // character to its last: the comma after the sign-off and the words before
        // the typo are common to both texts and are never selected.
        XCTAssertEqual(plan.writes[0].originalText, "Best")
        XCTAssertEqual(plan.writes[0].replacement, "Best regards")
        XCTAssertEqual(plan.writes[1].originalText, "'re help yesterday.")
        XCTAssertEqual(plan.writes[1].replacement, "r help yesterday.")
    }

    func testEarlierWritesKeepTheOffsetsThePlanMeasured() throws {
        // The first write changes the length of the last line. The second still has to
        // address the body where it actually is.
        let corrected = """
        Hi Bob,

        Thanks for your help yesterday.

        Kind regards and many thanks,
        Dustin
        dustin@example.com
        """
        let plan = try XCTUnwrap(plan(correcting: corrected))
        let source = composer as NSString

        for write in plan.writes {
            XCTAssertEqual(source.substring(with: write.documentRange), write.originalText)
        }
    }

    func testEachWriteExpectsTheFieldAsItWillBeAtThatMoment() async throws {
        let corrected = """
        Hi Bob,

        Thanks for your help yesterday.

        Best regards,
        Dustin
        dustin@example.com
        """
        let plan = try XCTUnwrap(plan(correcting: corrected))
        let host = RecordingHost(text: composer)

        let outcome = await TextReplacementRunner.run(plan) { await host.perform($0) }

        XCTAssertEqual(outcome, .applied)
        let finalText = await host.text
        XCTAssertEqual(finalText, corrected)
        let mismatches = await host.expectationMismatches
        XCTAssertEqual(mismatches, 0)
    }

    func testFinalTextIsReachedWhicheverRouteIsTaken() async throws {
        let corrected = composer.replacingOccurrences(of: "you're", with: "your")
        let plan = try XCTUnwrap(plan(correcting: corrected))
        let spanWrite = try XCTUnwrap(plan.spanWrite)

        let host = RecordingHost(text: composer)
        _ = await host.perform(spanWrite)

        let finalText = await host.text
        XCTAssertEqual(finalText, corrected)
        XCTAssertEqual(finalText, plan.updatedCapturedText)
    }

    // MARK: - What a host is asked before it is written to

    func testEveryWriteCoversSomethingTheHostCanBeAskedAbout() throws {
        // A correction that only adds a comma is narrowed to an insertion, and an
        // insertion selects nothing. Nothing is what every position in a document is
        // holding, so a host cannot refuse a write that is aimed at the wrong one.
        let captured = "Hi Bob how are you doing today"
        let plan = try XCTUnwrap(
            plan(
                correcting: "Hi Bob, how are you doing today",
                in: captured
            )
        )

        for write in plan.writes {
            XCTAssertGreaterThan(write.documentRange.length, 0)
            XCTAssertFalse(write.originalText.isEmpty)
        }
        let write = try XCTUnwrap(plan.writes.first)
        XCTAssertEqual(write.originalText, "b")
        XCTAssertEqual(write.replacement, "b,")
    }

    func testAWriteCarriesTheWritingAroundItForTheHostToConfirm() throws {
        let corrected = composer.replacingOccurrences(of: "you're", with: "your")
        let plan = try XCTUnwrap(plan(correcting: corrected))
        let source = composer as NSString

        for write in plan.writes {
            XCTAssertEqual(
                source.substring(with: write.neighbourhoodRange),
                write.neighbourhood
            )
            XCTAssertTrue(
                NSIntersectionRange(write.neighbourhoodRange, write.documentRange).length
                    == write.documentRange.length,
                "the confirmation has to cover the write it is confirming"
            )
            XCTAssertGreaterThan(
                write.neighbourhoodRange.length,
                write.documentRange.length
            )
        }
    }

    func testAHostWhoseOffsetsHaveDriftedIsRefusedRatherThanWrittenTo() async throws {
        // What a browser-backed editor does when the value it published and the offsets
        // it takes selections at have come apart: the same writing, at numbers three
        // characters along from the ones the plan measured. Every write would land in
        // the wrong place, and a narrowed one is short enough that the wrong place can
        // be holding exactly what the plan expected.
        let corrected = composer.replacingOccurrences(of: "you're", with: "your")
        let plan = try XCTUnwrap(plan(correcting: corrected))
        let host = RecordingHost(text: composer, offsetSkew: 3)

        let outcome = await TextReplacementRunner.run(plan) { await host.perform($0) }

        XCTAssertEqual(outcome, .refused(restoredWrites: 0))
        let finalText = await host.text
        XCTAssertEqual(finalText, composer, "a drifted host must be left exactly as it was")
    }

    func testADriftedHostWouldOtherwiseHaveTakenTheWriteOnItsOwnText() throws {
        // Why the surroundings are asked about at all: what a narrowed write covers is
        // short enough to appear all over a document, so the selection landing in the
        // wrong place answers with the right characters.
        let captured = "no, the meeting is at 3pm. Please let me no if that works."
        let plan = try XCTUnwrap(
            plan(
                correcting: "no, the meeting is at 3pm. Please let me know if that works.",
                in: captured
            )
        )
        let write = try XCTUnwrap(plan.writes.first)
        let source = captured as NSString

        XCTAssertEqual(write.originalText, "no")
        XCTAssertEqual(
            source.substring(with: NSRange(location: 0, length: 2)),
            write.originalText,
            "the same two characters sit at the front of the paragraph"
        )
        XCTAssertNotEqual(
            source.substring(
                with: NSRange(location: 0, length: write.neighbourhoodRange.length)
            ),
            write.neighbourhood,
            "the surroundings are what tell the two apart"
        )
    }

    func testAWriteThatCannotBeAccountedForStopsEverything() async throws {
        // A host that took a write and then read back as neither state. Nothing knows
        // what the document is holding, so nothing is put back and nothing else is
        // written: an undo aimed by the plan's numbers would be one more write into a
        // field whose offsets no longer mean anything.
        let plan = try XCTUnwrap(plan(correcting: twoLineCorrection))
        let host = RecordingHost(text: composer)

        let outcome = await TextReplacementRunner.run(plan) { write in
            await host.attempts == 1 ? .unverified : await host.perform(write)
        }

        XCTAssertEqual(outcome, .unverified(landedWrites: 1))
        let attempts = await host.attempts
        XCTAssertEqual(attempts, 1, "nothing may be written after an unaccountable write")
    }

    // MARK: - A host that numbers its text differently

    func testAShiftedPlanAddressesTheSameWritingFurtherAlong() throws {
        let corrected = composer.replacingOccurrences(of: "you're", with: "your")
        let plan = try XCTUnwrap(plan(correcting: corrected))
        let shifted = plan.shifted(by: 12)

        XCTAssertEqual(shifted.writes.count, plan.writes.count)
        for (write, moved) in zip(plan.writes, shifted.writes) {
            XCTAssertEqual(moved.documentRange.location, write.documentRange.location + 12)
            XCTAssertEqual(moved.documentRange.length, write.documentRange.length)
            XCTAssertEqual(
                moved.neighbourhoodRange.location,
                write.neighbourhoodRange.location + 12
            )
            XCTAssertEqual(
                moved.expectedCapturedRange.location,
                write.expectedCapturedRange.location + 12
            )
            // Only where it is written moves. What is written, and what has to be there
            // first, are the author's text and cannot move with it.
            XCTAssertEqual(moved.originalText, write.originalText)
            XCTAssertEqual(moved.replacement, write.replacement)
            XCTAssertEqual(moved.neighbourhood, write.neighbourhood)
        }
        XCTAssertEqual(shifted.capturedRange.location, plan.capturedRange.location + 12)
    }

    func testAShiftedPlanLandsOnAHostThatHadDrifted() async throws {
        let corrected = composer.replacingOccurrences(of: "you're", with: "your")
        let plan = try XCTUnwrap(plan(correcting: corrected))
        // The same writing, seven characters along from where the plan measured it.
        let padding = String(repeating: "\u{fffc}", count: 7)
        let host = RecordingHost(text: padding + composer)

        let outcome = await TextReplacementRunner.run(plan.shifted(by: 7)) {
            await host.perform($0)
        }

        XCTAssertEqual(outcome, .applied)
        let finalText = await host.text
        XCTAssertEqual(finalText, padding + corrected)
    }

    func testShiftingByNothingChangesNothing() throws {
        let plan = try XCTUnwrap(plan(correcting: twoLineCorrection))

        XCTAssertEqual(plan.shifted(by: 0), plan)
    }

    func testAShiftedPlanStillPutsBackWhatItLanded() async throws {
        let plan = try XCTUnwrap(plan(correcting: twoLineCorrection)).shifted(by: 7)
        let padding = String(repeating: "\u{fffc}", count: 7)
        let host = RecordingHost(text: padding + composer, refusingWriteAt: 1)

        let outcome = await TextReplacementRunner.run(plan) { await host.perform($0) }

        XCTAssertEqual(outcome, .refused(restoredWrites: 1))
        let finalText = await host.text
        XCTAssertEqual(finalText, padding + composer)
        let mismatches = await host.expectationMismatches
        XCTAssertEqual(mismatches, 0)
    }

    // MARK: - Refusals

    func testARefusedFirstWriteLeavesTheFieldUntouched() async throws {
        let corrected = composer.replacingOccurrences(of: "you're", with: "your")
        let plan = try XCTUnwrap(plan(correcting: corrected))
        let host = RecordingHost(text: composer, refusingWriteAt: 0)

        let outcome = await TextReplacementRunner.run(plan) { await host.perform($0) }

        XCTAssertEqual(outcome, .refused(restoredWrites: 0))
        let finalText = await host.text
        XCTAssertEqual(finalText, composer)
    }

    func testARefusalPartWayPutsBackWhatLanded() async throws {
        let plan = try XCTUnwrap(plan(correcting: twoLineCorrection))
        let host = RecordingHost(text: composer, refusingWriteAt: 1)

        let outcome = await TextReplacementRunner.run(plan) { await host.perform($0) }

        // One write landed and one write put it back, so the message is the author's
        // again rather than half somebody else's.
        XCTAssertEqual(outcome, .refused(restoredWrites: 1))
        let finalText = await host.text
        XCTAssertEqual(finalText, composer)
        let mismatches = await host.expectationMismatches
        XCTAssertEqual(mismatches, 0)
    }

    func testEveryLandedWriteIsPutBackWhenTheLastOneIsRefused() async throws {
        // Three changed lines, the last of them refused: both of the others have to come
        // back out, in the reverse of the order they went in.
        let corrected = """
        Hi Bob!

        Thanks for your help yesterday.

        Best regards,
        Dustin
        dustin@example.com
        """
        let plan = try XCTUnwrap(plan(correcting: corrected))
        XCTAssertEqual(plan.writes.count, 3)
        let host = RecordingHost(text: composer, refusingWriteAt: 2)

        let outcome = await TextReplacementRunner.run(plan) { await host.perform($0) }

        XCTAssertEqual(outcome, .refused(restoredWrites: 2))
        let finalText = await host.text
        XCTAssertEqual(finalText, composer)
        let mismatches = await host.expectationMismatches
        XCTAssertEqual(mismatches, 0)
    }

    func testARefusedUndoLeavesTheFieldPartlyCorrectedAndSaysSo() async throws {
        let plan = try XCTUnwrap(plan(correcting: twoLineCorrection))
        // The write lands, the refusal follows, and the host will not take the undo
        // either. There is nothing left to do but report it.
        let host = RecordingHost(text: composer, refusingWriteAt: 1, refusingUndo: true)

        let outcome = await TextReplacementRunner.run(plan) { await host.perform($0) }

        XCTAssertEqual(outcome, .partiallyApplied(landedWrites: 1, restoredWrites: 0))
        let finalText = await host.text
        XCTAssertTrue(finalText.contains("Best regards,"))
        XCTAssertTrue(finalText.contains("Thanks for you're help yesterday."))
    }

    func testAnUndoAddressesTheTextTheWriteActuallyLeftBehind() throws {
        let plan = try XCTUnwrap(plan(correcting: twoLineCorrection))
        let write = plan.writes[0]
        let undo = try XCTUnwrap(plan.rollback(afterWrites: 1).first)

        // The write put its replacement there, so that is what the undo has to select,
        // at the same place and with the replacement's own length.
        XCTAssertEqual(undo.documentRange.location, write.documentRange.location)
        XCTAssertEqual(undo.documentRange.length, (write.replacement as NSString).length)
        XCTAssertEqual(undo.originalText, write.replacement)
        XCTAssertEqual(undo.replacement, write.originalText)
        XCTAssertEqual(undo.expectedCapturedText, plan.capturedText)
    }

    func testNothingLandedMeansNothingToUndo() throws {
        let plan = try XCTUnwrap(plan(correcting: twoLineCorrection))

        XCTAssertTrue(plan.rollback(afterWrites: 0).isEmpty)
    }

    func testARefusalStopsTheRemainingWrites() async throws {
        let corrected = """
        Hi Bob,

        Thanks for your help yesterday.

        Best regards,
        Dustin
        dustin@example.com
        """
        let plan = try XCTUnwrap(plan(correcting: corrected))
        let host = RecordingHost(text: composer, refusingWriteAt: 0)

        _ = await TextReplacementRunner.run(plan) { await host.perform($0) }

        let attempts = await host.attempts
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - Nothing to write, and nothing to write against

    func testEquivalentTextIsNotWrittenAtAll() async throws {
        let plan = try XCTUnwrap(
            plan(correcting: composer.replacingOccurrences(of: "é", with: "é"))
        )
        let host = RecordingHost(text: composer)

        let outcome = await TextReplacementRunner.run(plan) { await host.perform($0) }

        XCTAssertEqual(outcome, .nothingToWrite)
        XCTAssertTrue(plan.writes.isEmpty)
        XCTAssertNil(plan.spanWrite)
        let attempts = await host.attempts
        XCTAssertEqual(attempts, 0)
    }

    func testCanonicallyEquivalentCorrectionIsNothingToWrite() throws {
        let plan = try XCTUnwrap(
            TextReplacementPlanner.plan(
                capturedText: "Un café serré",
                capturedLocation: 0,
                targetLocation: 0,
                targetText: "Un café serré",
                replacement: "Un cafe\u{0301} serre\u{0301}"
            )
        )

        XCTAssertTrue(plan.writes.isEmpty)
    }

    func testAMovedTargetIsRefusedRatherThanWrittenBlind() {
        XCTAssertNil(
            TextReplacementPlanner.plan(
                capturedText: composer,
                capturedLocation: 0,
                targetLocation: 4,
                targetText: "Thanks for you're help yesterday.",
                replacement: "Thanks for your help yesterday."
            )
        )
    }

    func testATargetRunningPastTheCapturedTextIsRefused() {
        XCTAssertNil(
            TextReplacementPlanner.plan(
                capturedText: "Short.",
                capturedLocation: 0,
                targetLocation: 0,
                targetText: "Short. And then some more that was never captured.",
                replacement: "Short. And then some more that was never captured!"
            )
        )
    }

    /// Stands in for the application being written to: it applies what it is told, and
    /// checks each write against what that write said the field would then read as.
    ///
    /// It also answers the question every real host is asked first — what are you
    /// holding around this range — because a host that is never asked cannot be got
    /// wrong, and getting it wrong is the failure these writes exist to survive.
    private actor RecordingHost {
        private(set) var text: String
        private(set) var attempts = 0
        private(set) var expectationMismatches = 0
        private let refusedIndex: Int?
        private let refusesUndo: Bool
        /// How far this host's own offsets sit from the ones the plan measured. Zero for
        /// a host that indexes its text one way, which a browser-backed editor is not
        /// always. A skewed host holds the same writing at different numbers, so a write
        /// aimed by the plan's numbers lands somewhere else entirely.
        private let offsetSkew: Int
        private var hasRefused = false

        init(
            text: String,
            refusingWriteAt refusedIndex: Int? = nil,
            refusingUndo refusesUndo: Bool = false,
            offsetSkew: Int = 0
        ) {
            self.text = text
            self.refusedIndex = refusedIndex
            self.refusesUndo = refusesUndo
            self.offsetSkew = offsetSkew
        }

        func perform(_ write: PlannedTextWrite) -> TextReplacementRunner.WriteResult {
            defer { attempts += 1 }
            if attempts == refusedIndex {
                hasRefused = true
                return .refused
            }
            // Everything after the refusal is an undo.
            if hasRefused, refusesUndo { return .refused }

            let source = text as NSString
            guard reads(write.neighbourhood, at: write.neighbourhoodRange) else {
                return .refused
            }
            let range = skewed(write.documentRange)
            guard NSMaxRange(range) <= source.length,
                  source.substring(with: range) == write.originalText else {
                expectationMismatches += 1
                return .refused
            }
            text = source.replacingCharacters(in: range, with: write.replacement)
            // What the write said the field would read as, read back from the range the
            // write said to read it from — the same question the real client asks, and
            // not the same as comparing the host's whole text, which in a host whose
            // offsets have moved holds writing the plan never captured.
            if !reads(write.expectedCapturedText, at: write.expectedCapturedRange) {
                expectationMismatches += 1
            }
            return .applied
        }

        /// What the host has at a range of its own, which is the plan's range moved by
        /// however far the two disagree.
        private func reads(_ expected: String, at range: NSRange) -> Bool {
            let source = text as NSString
            let actual = skewed(range)
            guard actual.location >= 0, NSMaxRange(actual) <= source.length else {
                return false
            }
            return source.substring(with: actual) == expected
        }

        private func skewed(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + offsetSkew, length: range.length)
        }
    }
}
