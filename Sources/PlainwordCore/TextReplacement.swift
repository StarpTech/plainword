import Foundation

/// One write against a host: what to select, what it should be holding, and what it
/// should be replaced with.
public struct PlannedTextWrite: Equatable, Sendable {
    /// What to select, in the host's own document offsets.
    public let documentRange: NSRange
    /// What that selection should be holding now, which the host is asked to confirm
    /// before anything is written.
    public let originalText: String
    /// What to write there. Never spans a line break unless the plan had no way to
    /// avoid one.
    public let replacement: String
    /// What the host should be holding around this write, and where, before anything is
    /// selected. This is the question a narrowed write cannot ask about itself: what it
    /// covers is a word or two, which a document holds in many places, while forty
    /// characters either side of it is unique writing. See `WriteConfirmation`.
    public let neighbourhood: String
    public let neighbourhoodRange: NSRange
    /// What the captured text should read as once this write has landed, and the range
    /// it should be read back from. Verification compares against these rather than
    /// against the final text, so a write is checked when it happens and not after
    /// everything else has moved.
    public let expectedCapturedText: String
    public let expectedCapturedRange: NSRange

    public init(
        documentRange: NSRange,
        originalText: String,
        replacement: String,
        neighbourhood: String,
        neighbourhoodRange: NSRange,
        expectedCapturedText: String,
        expectedCapturedRange: NSRange
    ) {
        self.documentRange = documentRange
        self.originalText = originalText
        self.replacement = replacement
        self.neighbourhood = neighbourhood
        self.neighbourhoodRange = neighbourhoodRange
        self.expectedCapturedText = expectedCapturedText
        self.expectedCapturedRange = expectedCapturedRange
    }

    /// What the host should be holding around this write once it has landed, and the
    /// range to read it back from.
    ///
    /// The wider check on the whole captured text says whether everything is where the
    /// plan expects it; this says whether *this* write went in. They differ when a host
    /// has changed something the plan never touched, and telling the two apart is what
    /// decides between carrying on and stopping with the document in an unknown state.
    public var appliedNeighbourhood: String {
        let text = neighbourhood as NSString
        let local = NSRange(
            location: documentRange.location - neighbourhoodRange.location,
            length: documentRange.length
        )
        guard local.location >= 0, NSMaxRange(local) <= text.length else {
            return neighbourhood
        }
        return text.replacingCharacters(in: local, with: replacement)
    }

    public var appliedNeighbourhoodRange: NSRange {
        NSRange(
            location: neighbourhoodRange.location,
            length: (appliedNeighbourhood as NSString).length
        )
    }

    /// The same write, addressed to a host that numbers its own text differently. Only
    /// the offsets move; what is written and what has to be there first do not.
    public func shifted(by delta: Int) -> PlannedTextWrite {
        PlannedTextWrite(
            documentRange: documentRange.shifted(by: delta),
            originalText: originalText,
            replacement: replacement,
            neighbourhood: neighbourhood,
            neighbourhoodRange: neighbourhoodRange.shifted(by: delta),
            expectedCapturedText: expectedCapturedText,
            expectedCapturedRange: expectedCapturedRange.shifted(by: delta)
        )
    }
}

extension NSRange {
    fileprivate func shifted(by delta: Int) -> NSRange {
        NSRange(location: location + delta, length: length)
    }
}

/// Every write a correction needs, worked out before any of them is attempted.
public struct TextReplacementPlan: Equatable, Sendable {
    /// The writes to attempt, in the order to attempt them. Empty when the field
    /// already reads as the correction does.
    public let writes: [PlannedTextWrite]
    /// The same correction as a single write covering everything that changed, for a
    /// host that would not take the writes above. Still narrowed, so it reaches no
    /// further than the correction did. `nil` when there is nothing to write.
    public let spanWrite: PlannedTextWrite?
    /// What the captured text should read as once the correction has been applied,
    /// however it was applied.
    public let updatedCapturedText: String
    public let updatedCapturedRange: NSRange
    /// What it read as before any of this was attempted, which is where a refusal
    /// part-way through has to put it back.
    public let capturedText: String
    public let capturedRange: NSRange

    public init(
        writes: [PlannedTextWrite],
        spanWrite: PlannedTextWrite?,
        updatedCapturedText: String,
        updatedCapturedRange: NSRange,
        capturedText: String,
        capturedRange: NSRange
    ) {
        self.writes = writes
        self.spanWrite = spanWrite
        self.updatedCapturedText = updatedCapturedText
        self.updatedCapturedRange = updatedCapturedRange
        self.capturedText = capturedText
        self.capturedRange = capturedRange
    }

    /// The same plan, addressed to a host that numbers its own text differently.
    ///
    /// A plan is arithmetic over a copy of the text, read out once through one
    /// attribute. The host takes selections through another, and the two are the same
    /// numbers only while the host says they are. When they are not, the difference is a
    /// distance: the same writing, further along. Everything the plan holds moves by it
    /// together, so a plan that has been shifted is still internally consistent, and
    /// every write in it is still confirmed against the host before it goes in.
    public func shifted(by delta: Int) -> TextReplacementPlan {
        guard delta != 0 else { return self }
        return TextReplacementPlan(
            writes: writes.map { $0.shifted(by: delta) },
            spanWrite: spanWrite?.shifted(by: delta),
            updatedCapturedText: updatedCapturedText,
            updatedCapturedRange: updatedCapturedRange.shifted(by: delta),
            capturedText: capturedText,
            capturedRange: capturedRange.shifted(by: delta)
        )
    }

    /// The writes that undo the first `landed` writes of this plan, in the order to
    /// attempt them.
    ///
    /// Every write is its own inverse with the two texts swapped, and the states to
    /// verify against are the ones the plan already recorded: undoing a write should
    /// leave the field reading exactly as it did before that write was made. The order
    /// is the reverse of the order they were made in, which is what keeps each one at
    /// the offset it was planned for: the writes run from the end of the correction
    /// backwards, so undoing the most recent one first puts the earlier ones back where
    /// they started.
    ///
    /// What this restores is the writing, not its formatting. A write carries plain
    /// characters in both directions, so text that lost its styling on the way in does
    /// not get it back on the way out. Undoing is worth doing anyway: a message with the
    /// author's words in it can be corrected again, and a half-corrected one is a
    /// sentence nobody wrote.
    public func rollback(afterWrites landed: Int) -> [PlannedTextWrite] {
        guard landed > 0, landed <= writes.count else { return [] }

        return (0..<landed).reversed().map { index in
            let write = writes[index]
            let restoredText = index == 0
                ? capturedText
                : writes[index - 1].expectedCapturedText
            // Undoing a write happens while the field is holding what that write left
            // behind, so that is the text its own surroundings have to be confirmed
            // against — not the text the plan started from.
            let currentText = write.expectedCapturedText as NSString
            let undoneRange = NSRange(
                location: write.documentRange.location - capturedRange.location,
                length: (write.replacement as NSString).length
            )
            let neighbourhoodRange = WriteConfirmation.neighbourhoodRange(
                for: undoneRange,
                in: currentText
            )
            return PlannedTextWrite(
                documentRange: NSRange(
                    location: write.documentRange.location,
                    length: (write.replacement as NSString).length
                ),
                originalText: write.replacement,
                replacement: write.originalText,
                neighbourhood: currentText.substring(with: neighbourhoodRange),
                neighbourhoodRange: NSRange(
                    location: capturedRange.location + neighbourhoodRange.location,
                    length: neighbourhoodRange.length
                ),
                expectedCapturedText: restoredText,
                expectedCapturedRange: NSRange(
                    location: capturedRange.location,
                    length: (restoredText as NSString).length
                )
            )
        }
    }
}

/// Turns a correction into the smallest set of writes that can carry it.
///
/// This is all of the arithmetic in one place, and deliberately so: it is pure, it is
/// decided before a single character is written, and it can be checked against a text
/// and a set of offsets in a test rather than against a live application. The two rules
/// it exists to enforce are that a write never covers text the correction left alone,
/// because a write carries plain characters and whatever formatting it lands on is
/// rebuilt from them, and that a write never covers a line break, because in a rich-text
/// editor a break is structure the host owns rather than a character it stores.
public enum TextReplacementPlanner {
    /// Returns the plan, or `nil` when the target is not where it is said to be, which
    /// means the field moved under the correction and nothing should be written at all.
    ///
    /// - Parameters:
    ///   - capturedText: the text read from the field, which verification reads back.
    ///   - capturedLocation: where that text starts in the host's document offsets.
    ///   - targetLocation: where the edited target starts, in the same offsets.
    ///   - targetText: what the target holds now.
    ///   - replacement: what the target should hold instead.
    public static func plan(
        capturedText: String,
        capturedLocation: Int,
        targetLocation: Int,
        targetText: String,
        replacement: String
    ) -> TextReplacementPlan? {
        let captured = capturedText as NSString
        let localTargetLocation = targetLocation - capturedLocation
        let targetLength = (targetText as NSString).length
        guard capturedLocation >= 0,
              localTargetLocation >= 0,
              localTargetLocation + targetLength <= captured.length,
              captured.substring(
                with: NSRange(location: localTargetLocation, length: targetLength)
              ) == targetText else {
            return nil
        }

        // Nothing to write: the two texts are the same writing, whatever code points
        // each of them happens to be spelled with.
        guard let changed = TextSpanNarrowing.narrow(
            original: targetText,
            replacement: replacement
        ) else {
            let unchangedRange = NSRange(
                location: capturedLocation,
                length: captured.length
            )
            return TextReplacementPlan(
                writes: [],
                spanWrite: nil,
                updatedCapturedText: capturedText,
                updatedCapturedRange: unchangedRange,
                capturedText: capturedText,
                capturedRange: unchangedRange
            )
        }

        let changedLocation = localTargetLocation + changed.originalUTF16Range.location
        var builder = WriteBuilder(
            capturedText: captured,
            capturedLocation: capturedLocation,
            bounds: NSRange(location: localTargetLocation, length: targetLength)
        )
        guard let spanWrite = builder.write(
            atCapturedLocation: changedLocation,
            originalText: changed.originalText,
            replacement: changed.replacement
        ) else {
            return nil
        }

        // The span is the fallback, so the running text has to go back to where it
        // started before the per-line writes are built on top of it.
        builder.reset()

        var writes: [PlannedTextWrite] = []
        if changed.originalText.contains(where: \.isNewline),
           let edits = LineSegmentedEditPlanner.plan(
            original: changed.originalText,
            replacement: changed.replacement
           ) {
            // Last line first: a write only moves the text after it, so every line not
            // yet written is still at the offset the plan measured for it.
            for edit in edits.reversed() {
                guard let write = builder.write(
                    atCapturedLocation: changedLocation + edit.originalUTF16Range.location,
                    originalText: edit.originalText,
                    replacement: edit.replacement
                ) else {
                    return nil
                }
                writes.append(write)
            }
        }
        if writes.isEmpty {
            writes = [spanWrite]
        }

        // Where the field lands is the same whichever of those routes it took.
        let updatedCaptured = captured.replacingCharacters(
            in: NSRange(location: localTargetLocation, length: targetLength),
            with: replacement
        )
        return TextReplacementPlan(
            writes: writes,
            spanWrite: spanWrite,
            updatedCapturedText: updatedCaptured,
            updatedCapturedRange: NSRange(
                location: capturedLocation,
                length: (updatedCaptured as NSString).length
            ),
            capturedText: capturedText,
            capturedRange: NSRange(location: capturedLocation, length: captured.length)
        )
    }

    /// Builds writes against a captured text that each write changes, so every one of
    /// them carries the state its own verification should find.
    private struct WriteBuilder {
        private let originalCapturedText: NSString
        private let capturedLocation: Int
        /// The target, in captured-text offsets. A write may grow to become something
        /// the host can confirm, but never past what the author asked to have edited.
        private let bounds: NSRange
        private var runningText: NSString

        init(capturedText: NSString, capturedLocation: Int, bounds: NSRange) {
            self.originalCapturedText = capturedText
            self.capturedLocation = capturedLocation
            self.bounds = bounds
            self.runningText = capturedText
        }

        mutating func reset() {
            runningText = originalCapturedText
        }

        mutating func write(
            atCapturedLocation location: Int,
            originalText: String,
            replacement: String
        ) -> PlannedTextWrite? {
            let length = (originalText as NSString).length
            let range = NSRange(location: location, length: length)
            guard location >= 0,
                  location + length <= runningText.length,
                  runningText.substring(with: range) == originalText else {
                return nil
            }

            // A write the host cannot be asked about is grown until it can be, and then
            // carries the characters it grew over back unchanged.
            let confirmable = WriteConfirmation.confirmableRange(
                range,
                in: runningText,
                bounds: bounds
            )
            let leading = runningText.substring(
                with: NSRange(
                    location: confirmable.location,
                    length: range.location - confirmable.location
                )
            )
            let trailing = runningText.substring(
                with: NSRange(
                    location: NSMaxRange(range),
                    length: NSMaxRange(confirmable) - NSMaxRange(range)
                )
            )
            let confirmableOriginal = leading + originalText + trailing
            let confirmableReplacement = leading + replacement + trailing
            let neighbourhood = WriteConfirmation.neighbourhoodRange(
                for: confirmable,
                in: runningText
            )

            let nextText = runningText.replacingCharacters(
                in: confirmable,
                with: confirmableReplacement
            )
            defer { runningText = nextText as NSString }
            return PlannedTextWrite(
                documentRange: NSRange(
                    location: capturedLocation + confirmable.location,
                    length: confirmable.length
                ),
                originalText: confirmableOriginal,
                replacement: confirmableReplacement,
                neighbourhood: runningText.substring(with: neighbourhood),
                neighbourhoodRange: NSRange(
                    location: capturedLocation + neighbourhood.location,
                    length: neighbourhood.length
                ),
                expectedCapturedText: nextText,
                expectedCapturedRange: NSRange(
                    location: capturedLocation,
                    length: (nextText as NSString).length
                )
            )
        }
    }
}

/// Carries out a plan against a host, and leaves the field in a state the caller can
/// reason about.
///
/// The sequencing lives here rather than at the call site because what happens after a
/// refusal is the part that matters. Every write that landed before it is already in the
/// author's document, and a half-corrected message is worse than an uncorrected one: it
/// is a sentence nobody wrote, in writing that is about to be sent to somebody. So a
/// refusal is followed by putting back what landed, and the caller is told whether that
/// worked, because a field that was restored is safe to try another way and a field that
/// was not is not safe to touch at all.
public enum TextReplacementRunner {
    /// How a single write went.
    ///
    /// The distinction that matters is between a host that would not take a write and a
    /// host that took one and then did not read back as it should. The first leaves the
    /// field as it was, so the writes before it can be put back and another strategy can
    /// be tried. The second means something happened that nobody planned, and the field
    /// can no longer be reasoned about from the plan: putting writes back would be
    /// writing into offsets whose meaning is unknown, which is how a correction becomes
    /// damage.
    public enum WriteResult: Equatable, Sendable {
        /// The write landed, and the field reads as the plan said it would.
        case applied
        /// The host would not take it. The field holds what it held.
        case refused
        /// It was attempted, and the field reads as neither state. Nothing more may be
        /// written.
        case unverified
    }

    public enum Outcome: Equatable, Sendable {
        /// Every write landed.
        case applied
        /// The field already read as the correction did.
        case nothingToWrite
        /// The host refused a write, and the field holds what it held to begin with:
        /// either nothing had landed yet, or everything that had was put back.
        case refused(restoredWrites: Int)
        /// The host refused a write and then refused to undo one, so part of the
        /// correction is in the field. Nothing else should be written to it.
        case partiallyApplied(landedWrites: Int, restoredWrites: Int)
        /// A write was attempted and the field afterwards read as neither the state
        /// before it nor the state after it. What is in the document is unknown, so
        /// nothing was put back and nothing else may be written.
        case unverified(landedWrites: Int)
    }

    /// Runs where its caller runs. A host is reached through whatever isolation owns it,
    /// and inheriting that is what lets the caller hand over a closure that touches it.
    public static func run(
        isolation: isolated (any Actor)? = #isolation,
        _ plan: TextReplacementPlan,
        perform: (PlannedTextWrite) async throws -> WriteResult
    ) async rethrows -> Outcome {
        guard !plan.writes.isEmpty else { return .nothingToWrite }

        var landed = 0
        for write in plan.writes {
            switch try await perform(write) {
            case .applied:
                landed += 1
            case .refused:
                return try await restore(plan, landed: landed, perform: perform)
            case .unverified:
                // Undoing needs to know what the field is holding, and this is the one
                // answer that says nobody knows.
                return .unverified(landedWrites: landed)
            }
        }
        return .applied
    }

    /// Puts back the writes that landed, most recent first.
    ///
    /// A refused undo stops the rest: the writes are inverses of each other in a
    /// particular order, and one that did not happen leaves every later one addressing
    /// text that is not there. Better to stop and say so than to write into offsets that
    /// no longer mean anything.
    private static func restore(
        isolation: isolated (any Actor)? = #isolation,
        _ plan: TextReplacementPlan,
        landed: Int,
        perform: (PlannedTextWrite) async throws -> WriteResult
    ) async rethrows -> Outcome {
        guard landed > 0 else { return .refused(restoredWrites: 0) }

        var restored = 0
        for write in plan.rollback(afterWrites: landed) {
            switch try await perform(write) {
            case .applied:
                restored += 1
            case .refused, .unverified:
                return .partiallyApplied(landedWrites: landed, restoredWrites: restored)
            }
        }
        return .refused(restoredWrites: restored)
    }
}
