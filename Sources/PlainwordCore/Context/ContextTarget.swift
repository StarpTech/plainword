import CoreGraphics
import Foundation

/// The writing site a context assembly is gathered for.
///
/// Everything here is already known by the time the field itself has been captured, so
/// describing it costs the sources nothing to receive and saves each of them
/// rediscovering the same facts.
public struct ContextTarget: Sendable {
    public let element: ElementRef
    public let applicationName: String
    public let bundleIdentifier: String?
    public let targetKind: TextEditTargetKind
    /// The text already read from the field. Sources use it to avoid handing back
    /// writing the request is already carrying.
    public let capturedText: String
    /// The editable target within `capturedText`.
    public let targetRange: NSRange

    public init(
        element: ElementRef,
        applicationName: String,
        bundleIdentifier: String?,
        targetKind: TextEditTargetKind,
        capturedText: String = "",
        targetRange: NSRange = NSRange(location: 0, length: 0)
    ) {
        self.element = element
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.targetKind = targetKind
        self.capturedText = capturedText
        self.targetRange = targetRange
    }

    public var need: ContextNeed {
        ContextNeed(targetKind)
    }

    /// The editable target itself, when it lies inside the captured text.
    public var targetText: String {
        let source = capturedText as NSString
        guard targetRange.location >= 0,
              targetRange.length > 0,
              NSMaxRange(targetRange) <= source.length else {
            return ""
        }
        return source.substring(with: targetRange)
    }

    /// Text a source should not hand back, because the request already carries it.
    public var excludedTexts: [String] {
        [capturedText, targetText, applicationName].filter { !$0.isEmpty }
    }
}

/// One way of finding context, and the tier it belongs to.
///
/// Sources are ordered by cost and trustworthiness rather than by how much they tend to
/// return. A source that runs later is not a worse source in general — it is a more
/// expensive or more speculative way of answering the same question, and it earns its
/// turn only when the cheaper ones have not answered it.
public protocol ContextSource: Sendable {
    var tier: ContextTier { get }
    var name: String { get }

    /// A cheap decision made from the target alone, spending no round trips. A source
    /// that cannot apply here should say so rather than reading its way to the same
    /// conclusion.
    func supports(_ target: ContextTarget) -> Bool

    func read(_ workspace: ContextWorkspace) -> [ReadOnlyContextCandidate]
}

public extension ContextSource {
    func supports(_ target: ContextTarget) -> Bool { true }

    func provenance(_ confidence: ContextConfidence) -> ContextProvenance {
        ContextProvenance(tier: tier, source: name, confidence: confidence)
    }
}
