import Foundation

/// How far down the ordered list of sources a piece of context came from. Lower is both
/// cheaper and more trustworthy.
public enum ContextTier: Int, Comparable, CaseIterable, Sendable {
    /// Identity: what the application publishes about the field and the document.
    case identity = 0
    /// Continuous text: the passage the caret actually sits in.
    case passage = 1
    /// Structure: transcripts and landmarks, found by role rather than position.
    case structure = 2
    /// Geometry: whatever proximity can turn up. The last resort.
    case proximity = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Whether the application said this, or Plainword worked it out from the layout.
///
/// The distinction is the whole reliability argument. A label an application publishes
/// through `AXTitleUIElement` is that application stating a fact; a rectangle sitting
/// forty points above the caret is a guess that happens to be right most of the time.
/// Ranking them alike is how a date header came to be labelled a field hint.
public enum ContextConfidence: Int, Comparable, Sendable {
    case inferred = 0
    case stated = 1

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ContextProvenance: Equatable, Hashable, Sendable {
    public let tier: ContextTier
    public let source: String
    public let confidence: ContextConfidence

    public init(tier: ContextTier, source: String, confidence: ContextConfidence) {
        self.tier = tier
        self.source = source
        self.confidence = confidence
    }
}
