import Foundation

/// Whether what has been gathered answers the request, so the remaining sources can be
/// skipped.
///
/// Deliberately not a length test over everything collected. Tier 0 always returns
/// something — a field name, a window title — and treating that as an answer would end
/// every run before the sources that find writing had a turn. What satisfies a request
/// is prose: the conversation above the composer, the paragraphs before the caret.
///
/// The threshold is set to be reluctant on purpose. Declaring a need met when it is not
/// produces a worse suggestion that merely arrives sooner, and that failure is invisible
/// — there is nothing in the result to show what was never looked for. Being wrong in
/// the other direction only costs round trips that were budgeted anyway.
public enum ContextSufficiency {
    /// How much prose each kind of request has to have found before the expensive
    /// sources are skipped.
    public static func requiredProseLength(for need: ContextNeed) -> Int {
        if need.sendsNothing { return 0 }
        return need == .hungry ? 600 : 200
    }

    public static func isSatisfied(
        by candidates: [ReadOnlyContextCandidate],
        for need: ContextNeed
    ) -> Bool {
        let required = requiredProseLength(for: need)
        guard required > 0 else { return true }
        return proseLength(of: candidates) >= required
    }

    /// Only the kinds that carry running text count. A field label is identity, not
    /// context, however long it happens to be.
    public static func proseLength(of candidates: [ReadOnlyContextCandidate]) -> Int {
        candidates.reduce(into: 0) { total, candidate in
            switch candidate.kind {
            case .relatedPrecedingContent, .relatedContent:
                total += (candidate.text as NSString).length
            case .sourceApplication, .fieldLabel, .fieldIdentity, .fieldPlaceholder,
                 .fieldDescription, .fieldHelp, .documentTitle:
                break
            }
        }
    }
}
