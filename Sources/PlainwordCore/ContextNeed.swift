import Foundation

/// How much of the surrounding writing a particular request actually needs.
///
/// Every request used to receive the same allowance regardless of what it was for, which
/// suited none of them: a draft at an empty caret has no target text at all — the writing
/// around it is the entire input — while a whole-field rewrite already holds everything
/// it needs and only wants to know where it is.
///
/// Budgets differ by side as well as by size. Writing continues forwards, so what comes
/// before the caret says far more about what belongs next than what follows it does.
public struct ContextNeed: Equatable, Hashable, Sendable {
    public let leading: PassageBudget
    public let trailing: PassageBudget

    public init(leading: PassageBudget, trailing: PassageBudget) {
        self.leading = leading
        self.trailing = trailing
    }

    /// The target is the whole field, so there is nothing around it to send.
    public static let identityOnly = ContextNeed(leading: .none, trailing: .none)

    /// An edit to existing text, which carries its own meaning and needs the surrounding
    /// sentences only to resolve references and match the voice around it.
    public static let modest = ContextNeed(
        leading: PassageBudget(maximumUTF16Length: 400, preferredBoundary: .sentence),
        trailing: PassageBudget(maximumUTF16Length: 300, preferredBoundary: .sentence)
    )

    /// A draft written from nothing. Paragraph edges matter here more than anywhere
    /// else: a continuation that begins from half a sentence tends to be written as a
    /// fresh thought rather than as the next one.
    public static let hungry = ContextNeed(
        leading: PassageBudget(maximumUTF16Length: 1_200, preferredBoundary: .paragraph),
        trailing: PassageBudget(maximumUTF16Length: 400, preferredBoundary: .paragraph)
    )

    public init(_ targetKind: TextEditTargetKind) {
        switch targetKind {
        case .insertionPoint:
            self = .hungry
        case .selection, .sentence, .paragraph:
            self = .modest
        case .document:
            self = .identityOnly
        }
    }

    public var sendsNothing: Bool {
        leading.maximumUTF16Length == 0 && trailing.maximumUTF16Length == 0
    }

    /// The same need with both budgets scaled, for an application whose text is reached
    /// through an interface that makes long reads expensive.
    public func scaled(by factor: Double) -> ContextNeed {
        guard factor != 1, factor >= 0 else { return self }
        return ContextNeed(
            leading: PassageBudget(
                maximumUTF16Length: Int(Double(leading.maximumUTF16Length) * factor),
                preferredBoundary: leading.preferredBoundary
            ),
            trailing: PassageBudget(
                maximumUTF16Length: Int(Double(trailing.maximumUTF16Length) * factor),
                preferredBoundary: trailing.preferredBoundary
            )
        )
    }
}
