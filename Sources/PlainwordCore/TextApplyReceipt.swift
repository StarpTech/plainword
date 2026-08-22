import Foundation

/// A record of what happened when a suggestion was written into an application.
///
/// The debug views have always been able to show the conversation with the model and
/// nothing about the half of the work that touches the author's document. That is the
/// half that can quietly ruin a message: a write that covered more than it needed to, a
/// strategy that replaced a whole field, a refusal that left half a correction behind.
/// None of it left a trace, so a report of damage could only be answered by reading the
/// source and reasoning about what must have run.
///
/// This is that trace. One line per apply, saying how much was written, where, by which
/// strategy, and how it ended.
public struct TextApplyReceipt: Identifiable, Equatable, Sendable {
    /// How the writing was carried out. The order here is the order they are tried in,
    /// and each one covers more of the document than the last.
    public enum Strategy: String, Equatable, Sendable {
        /// One write per changed line, leaving the line breaks alone.
        case perLine
        /// A single write covering everything the correction changed.
        case span
        /// The field's whole value replaced at once, which no rich-text editor survives
        /// with its formatting intact.
        case wholeValue
        /// Selected and typed.
        case keyboard

        public var description: String {
            switch self {
            case .perLine: "line by line"
            case .span: "one write"
            case .wholeValue: "whole field"
            case .keyboard: "typed"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case applied(Strategy)
        /// The field already read as the suggestion did, so nothing was written.
        case unchanged
        /// A write was refused, and everything that had landed was put back.
        case restored(writes: Int)
        /// A write was refused and could not be undone. The field holds part of it.
        case partiallyApplied(landedWrites: Int, restoredWrites: Int)
        /// A write was attempted and the field then read as neither the state before it
        /// nor the state after it, so nothing further was written or put back.
        case unverified(landedWrites: Int)
        case failed(String)
    }

    public let id: UUID
    public let startedAt: Date
    public let completedAt: Date
    public let applicationName: String
    /// What was being edited: a sentence, a paragraph, a selection, the document.
    public let targetKind: String
    public let targetUTF16Length: Int
    /// What the correction actually changed, in the host's own offsets, which is what
    /// every write was confined to.
    public let changedRange: NSRange
    public let plannedWrites: Int
    /// Whether the field belongs to a web page, which decides whether the whole-value
    /// write was available at all.
    public let isWebArea: Bool
    public let outcome: Outcome

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        completedAt: Date,
        applicationName: String,
        targetKind: String,
        targetUTF16Length: Int,
        changedRange: NSRange,
        plannedWrites: Int,
        isWebArea: Bool,
        outcome: Outcome
    ) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.applicationName = applicationName
        self.targetKind = targetKind
        self.targetUTF16Length = targetUTF16Length
        self.changedRange = changedRange
        self.plannedWrites = plannedWrites
        self.isWebArea = isWebArea
        self.outcome = outcome
    }

    public var duration: TimeInterval {
        completedAt.timeIntervalSince(startedAt)
    }

    /// Whether this apply is one to look at, which is what the debug view filters on.
    public var isFailure: Bool {
        switch outcome {
        case .applied, .unchanged, .restored:
            false
        case .partiallyApplied, .unverified, .failed:
            true
        }
    }

    /// How much of the target the writes were allowed to touch, as a share of it. A
    /// correction to one sentence of an email should be a few percent; anything near
    /// the whole of it is a write that will take the formatting with it.
    public var changedShare: Double {
        guard targetUTF16Length > 0 else { return 0 }
        return min(1, Double(changedRange.length) / Double(targetUTF16Length))
    }

    /// The line the debug view shows.
    public var summary: String {
        var parts = [
            "\(targetKind), \(targetUTF16Length) chars",
            plannedWrites == 1 ? "1 write" : "\(plannedWrites) writes",
            "chars \(changedRange.location)–\(NSMaxRange(changedRange))"
        ]
        if isWebArea {
            parts.append("web page")
        }
        parts.append(outcomeDescription)
        return parts.joined(separator: " · ")
    }

    public var outcomeDescription: String {
        switch outcome {
        case .applied(let strategy):
            "applied \(strategy.description)"
        case .unchanged:
            "nothing to write"
        case .restored(let writes):
            writes == 0
                ? "refused, field untouched"
                : "refused, \(writes) put back"
        case let .partiallyApplied(landed, restored):
            "REFUSED PART-WAY, \(landed) landed, \(restored) put back"
        case .unverified(let landed):
            "STOPPED, \(landed) landed, the next write could not be confirmed"
        case .failed(let message):
            "failed: \(message)"
        }
    }
}
