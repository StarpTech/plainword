import Foundation

/// What is known about how one application exposes its text.
///
/// A profile may reorder sources, switch one off, or scale the passage budgets. It may
/// not add behaviour of its own — so the generic path stays the one that every
/// application exercises, and no application can come to depend on a special case that
/// nothing else tests.
public struct ApplicationProfile: Equatable, Sendable {
    public var disabledSources: Set<String>
    public var passageBudgetScale: Double
    /// Extra roles to treat as a transcript container, for an application whose
    /// conversation is not in a table, outline, or list.
    public var additionalTranscriptRoles: Set<String>
    /// Whether the surrounding interface is worth traversing at all. An editor that
    /// exposes only a sliding window of its document has nothing useful outside the
    /// field, and crawling for it spends a budget on noise.
    public var harvestsSurroundingInterface: Bool

    public init(
        disabledSources: Set<String> = [],
        passageBudgetScale: Double = 1,
        additionalTranscriptRoles: Set<String> = [],
        harvestsSurroundingInterface: Bool = true
    ) {
        self.disabledSources = disabledSources
        self.passageBudgetScale = passageBudgetScale
        self.additionalTranscriptRoles = additionalTranscriptRoles
        self.harvestsSurroundingInterface = harvestsSurroundingInterface
    }

    public static let generic = ApplicationProfile()

    public func need(for targetKind: TextEditTargetKind) -> ContextNeed {
        ContextNeed(targetKind).scaled(by: passageBudgetScale)
    }

    public func allows(_ source: some ContextSource) -> Bool {
        if disabledSources.contains(source.name) { return false }
        if !harvestsSurroundingInterface {
            return source.tier <= .identity
        }
        return true
    }

    // MARK: - The table

    public static func profile(forBundleIdentifier identifier: String?) -> ApplicationProfile {
        guard let identifier else { return .generic }
        return known[identifier] ?? .generic
    }

    /// Kept short on purpose. Every entry is a claim about another team's software that
    /// can quietly stop being true, so an application earns one only where the generic
    /// path is measurably wrong for it.
    private static let known: [String: ApplicationProfile] = [
        // Monaco publishes a sliding window of rendered lines rather than the file, and
        // the interface around it is a file tree and a terminal. Neither is context for
        // the prose being written in a comment or a commit message.
        "com.microsoft.VSCode": ApplicationProfile(harvestsSurroundingInterface: false),
        "com.todesktop.230313mzl4w4u92": ApplicationProfile(
            harvestsSurroundingInterface: false
        ),
        // The whole note is inside the focused text area, so the surrounding interface
        // holds only the note list and a date header — the header being the very thing
        // that used to be attached as a field hint.
        "com.apple.Notes": ApplicationProfile(
            disabledSources: [ProximityCrawlSource.sourceName]
        ),
        // The transcript is a separate scroll area from the composer, so structure finds
        // it and proximity only rediscovers it more expensively.
        "com.apple.MobileSMS": ApplicationProfile(
            disabledSources: [ProximityCrawlSource.sourceName]
        )
    ]
}
