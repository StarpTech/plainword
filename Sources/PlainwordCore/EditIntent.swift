import Foundation

public enum EditIntent: String, Equatable, Hashable, Sendable {
    case correct
    case correctOrComplete
    /// Write new text from an instruction alone, with no existing text to edit.
    case compose

    /// The classifications a result may carry under this intent. Both providers
    /// constrain their structured output to these, so a value the panel cannot
    /// present never comes back.
    public var allowedClassifications: [WritingSuggestionKind] {
        switch self {
        case .correct: [.correction, .rewrite]
        case .correctOrComplete: [.correction, .rewrite, .completion]
        case .compose: [.rewrite]
        }
    }
}
