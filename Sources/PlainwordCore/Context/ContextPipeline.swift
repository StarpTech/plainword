import Foundation

public struct ContextAssembly: Equatable, Sendable {
    public let fragments: [ReadOnlyContextFragment]
    public let telemetry: ContextTelemetry

    public init(fragments: [ReadOnlyContextFragment], telemetry: ContextTelemetry) {
        self.fragments = fragments
        self.telemetry = telemetry
    }

    public static let empty = ContextAssembly(fragments: [], telemetry: ContextTelemetry())
}

/// Everything the sources found, before it has been narrowed to fit one request.
///
/// Reading the screen is what costs; choosing which of it travels is arithmetic over
/// text. Keeping the two apart is what lets one reading answer more than one request:
/// a harvest taken at an empty caret can serve the correction that follows it, narrowed
/// against that correction's own words rather than against whatever the field held when
/// the screen was read.
public struct ContextHarvest: Equatable, Sendable {
    public let candidates: [ReadOnlyContextCandidate]
    public let telemetry: ContextTelemetry

    public init(candidates: [ReadOnlyContextCandidate], telemetry: ContextTelemetry) {
        self.candidates = candidates
        self.telemetry = telemetry
    }

    public static let empty = ContextHarvest(candidates: [], telemetry: ContextTelemetry())

    /// What this particular writing site should be sent.
    ///
    /// The target decides three things a harvest cannot: which candidates repeat writing
    /// the request already carries, which of the rest speak to the words being edited,
    /// and how much of them a target this long is worth. All three change as the author
    /// writes, so none of them may be settled at harvest time.
    public func assembly(for target: ContextTarget) -> ContextAssembly {
        ContextAssembly(
            fragments: ReadOnlyContextRanker.select(
                from: candidates,
                excluding: target.excludedTexts,
                relatedTo: target.targetText,
                maximumUTF16Length: ReadOnlyContextGeometry.budgetUTF16Length(
                    targetUTF16Length: target.targetRange.length
                )
            ),
            telemetry: telemetry
        )
    }
}

/// Runs the sources in order and stops as soon as the request has what it needs.
///
/// The ordering is the design. Sources are tried cheapest and most trustworthy first,
/// they share one allowance, and the run ends at a tier boundary rather than after every
/// source — because two sources in the same tier are alternative ways of answering the
/// same question, and stopping between them would mean the answer depended on which one
/// happened to be listed first.
public struct ContextPipeline: Sendable {
    public let sources: [any ContextSource]

    public init(sources: [any ContextSource] = ContextPipeline.standardSources) {
        // Sorted by tier, and by the order given within one. Swift's sort makes no
        // stability promise, and two sources in the same tier are alternatives whose
        // relative order decides which one answers first — leaving that to the sort
        // would mean the context depended on something nobody wrote down.
        self.sources = sources.enumerated()
            .sorted { left, right in
                left.element.tier == right.element.tier
                    ? left.offset < right.offset
                    : left.element.tier < right.element.tier
            }
            .map(\.element)
    }

    public static let standardSources: [any ContextSource] = [
        FieldIdentitySource(),
        DocumentIdentitySource(),
        MarkerPassageSource(),
        TranscriptSource(),
        ScreenLadderSource(),
        ProximityCrawlSource()
    ]

    /// Runs every source, whether or not the request still needed one.
    ///
    /// Only for recording. A fixture can answer exactly the questions that were asked
    /// while it was captured, so a recording taken through the ordinary run holds
    /// evidence for one strategy — whichever happened to answer first — and none at all
    /// for the others. That is the wrong shape for a corpus, whose entire purpose is
    /// settling which strategy *should* answer in a given application. A recording made
    /// this way can be replayed against a pipeline ordered any way at all.
    ///
    /// It costs more reads than a real harvest, which is affordable exactly once: while
    /// a person is deliberately capturing a case, with nothing waiting on the result.
    public func harvestExhaustively(_ workspace: ContextWorkspace) -> ContextHarvest {
        var candidates: [ReadOnlyContextCandidate] = []
        for source in sources where source.supports(workspace.target) {
            let produced = source.read(workspace)
            if !produced.isEmpty {
                workspace.telemetry.contributingSources.append(source.name)
            }
            candidates.append(contentsOf: produced)
        }
        workspace.telemetry.roundTrips = workspace.budget.spentRoundTrips
        return ContextHarvest(candidates: candidates, telemetry: workspace.telemetry)
    }

    public func assemble(_ workspace: ContextWorkspace) -> ContextAssembly {
        harvest(workspace).assembly(for: workspace.target)
    }

    /// Reads the screen and stops, handing back everything the sources turned up.
    public func harvest(_ workspace: ContextWorkspace) -> ContextHarvest {
        let target = workspace.target
        let need = workspace.profile.need(for: target.targetKind)
        var candidates: [ReadOnlyContextCandidate] = []
        var completedTier: ContextTier?
        var stoppedAt: Int?

        for (index, source) in sources.enumerated() {
            guard workspace.profile.allows(source), source.supports(target) else {
                workspace.telemetry.skippedSources.append(source.name)
                continue
            }
            if let completedTier,
               source.tier > completedTier,
               ContextSufficiency.isSatisfied(by: candidates, for: need) {
                workspace.telemetry.satisfiedAfterTier = completedTier
                stoppedAt = index
                break
            }
            if workspace.budget.isExhausted {
                stoppedAt = index
                break
            }

            let produced = source.read(workspace)
            if !produced.isEmpty {
                workspace.telemetry.contributingSources.append(source.name)
            }
            candidates.append(contentsOf: produced)
            completedTier = source.tier
        }

        if let stoppedAt {
            workspace.telemetry.skippedSources.append(
                contentsOf: sources[stoppedAt...].map(\.name)
            )
        }

        workspace.telemetry.roundTrips = workspace.budget.spentRoundTrips
        workspace.telemetry.reachedRoundTripLimit = workspace.budget.reachedRoundTripLimit
        workspace.telemetry.reachedTimeLimit = workspace.budget.reachedTimeLimit
        workspace.telemetry.requiredProseLength =
            ContextSufficiency.requiredProseLength(for: need)
        workspace.telemetry.harvestedProseLength = ContextSufficiency.proseLength(of: candidates)

        return ContextHarvest(candidates: candidates, telemetry: workspace.telemetry)
    }
}
