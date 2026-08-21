import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import PlainwordCore

/// Runs the context pipeline off the main actor, and remembers what it found.
///
/// Two things move here that used to be fixed. The harvest no longer has to finish
/// inside the pause between a keystroke and a popover, because it can be started when
/// focus lands rather than when the author asks for something — the focus notification
/// was already being delivered and nothing was being done with it. And what it found is
/// kept for a few seconds, so a second request against a screen that has not moved costs
/// a dictionary lookup.
///
/// Being an actor also serialises harvests, which matters for the same reason it did
/// before: two overlapping ones would flood the same application with traffic.
actor ContextService {
    struct Request: Sendable {
        let element: AXElementBox
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let applicationName: String
        let targetKind: TextEditTargetKind
        let capturedText: String
        let targetRange: NSRange
        let primaryScreenMaxY: CGFloat
    }

    /// Nobody is waiting on a prefetch, so it may look further than a request dares to.
    private let prefetchBudget = (roundTrips: 320, duration: Duration.milliseconds(600))
    /// A request that missed the cache still has to feel instant.
    private let requestBudget = (roundTrips: 280, duration: Duration.milliseconds(200))

    /// How long a harvest describes the screen it was taken from.
    ///
    /// Nothing cheap reports that a view scrolled, and a stale fragment is worse than a
    /// missing one because it reads as current. A few seconds covers the pause between
    /// landing in a field and asking for help, and expires well before the surroundings
    /// could have changed unnoticed.
    private let freshness: Duration = .seconds(5)

    private struct CacheKey: Hashable {
        let processIdentifier: pid_t
        let element: AXElementKey
    }

    private struct CachedHarvest {
        let harvest: ContextHarvest
        let takenAt: ContinuousClock.Instant
        /// What the harvest was looking for. A demanding need reads further before it is
        /// satisfied, so its result also answers every lesser one — which is what lets a
        /// prefetch taken for a draft serve the correction that actually follows.
        let need: ContextNeed
    }

    private let pipeline = ContextPipeline()
    private let clock = ContinuousClock()
    private var cache: [CacheKey: CachedHarvest] = [:]
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.Plainword",
        category: "ContextService"
    )

    /// The fragments to attach to a request, harvesting them if the cache cannot answer.
    ///
    /// A remembered harvest is narrowed again here rather than handed back as it was
    /// found. What the screen holds is what got cached; which of it belongs to *this*
    /// request depends on the text in the field right now, and that text may have moved
    /// on since — the author typed, or a suggestion was applied over it. Re-narrowing is
    /// arithmetic over strings, so it costs nothing worth saving, and skipping it would
    /// let a request be sent writing the field no longer contains.
    func assembly(for request: Request) -> ContextAssembly {
        let profile = ApplicationProfile.profile(
            forBundleIdentifier: request.bundleIdentifier
        )
        let key = CacheKey(
            processIdentifier: request.processIdentifier,
            element: AXElementKey(request.element.element)
        )
        let need = profile.need(for: request.targetKind)
        // Built before the cache is consulted only so that the target has a handle to
        // name the field by. A reused harvest never dereferences it — nothing here reads
        // the screen again — and an unused reader is three empty tables.
        let reader = LiveAccessibilityReader(
            root: request.element.element,
            primaryScreenMaxY: request.primaryScreenMaxY
        )
        let target = target(for: request, at: reader.rootReference)

        if let cached = cached(key, answering: need) {
            return cached.assembly(for: target)
        }

        let harvested = harvest(
            reader: reader,
            target: target,
            profile: profile,
            budget: ContextBudget(
                maximumRoundTrips: requestBudget.roundTrips,
                duration: requestBudget.duration
            )
        )
        cache[key] = CachedHarvest(harvest: harvested, takenAt: clock.now, need: need)
        log(harvested.telemetry, for: request)
        return harvested.assembly(for: target)
    }

    /// A remembered harvest, if it is still current and looked at least as hard as this
    /// request needs it to have.
    private func cached(_ key: CacheKey, answering need: ContextNeed) -> ContextHarvest? {
        guard let cached = cache[key], clock.now - cached.takenAt < freshness else {
            return nil
        }
        guard ContextSufficiency.requiredProseLength(for: cached.need)
            >= ContextSufficiency.requiredProseLength(for: need) else {
            return nil
        }
        return cached.harvest
    }

    /// Reads a field's surroundings before anything has been asked of them.
    ///
    /// Called when focus lands. A prefetch that turns out to be wasted costs nothing the
    /// author can feel; one that lands takes the whole harvest off the request path.
    func prewarm(_ request: Request) async {
        let profile = ApplicationProfile.profile(
            forBundleIdentifier: request.bundleIdentifier
        )
        let key = CacheKey(
            processIdentifier: request.processIdentifier,
            element: AXElementKey(request.element.element)
        )
        let need = profile.need(for: request.targetKind)
        if cached(key, answering: need) != nil { return }

        var harvested = harvestOnce(request, profile: profile)

        // A Chromium application that had switched its tree off answers the first read
        // with the shape of a page and none of its words: enabling it again is a request
        // rather than a command, and the tree is built after the answer has been given.
        // Nothing is waiting on a prefetch, so it can afford to ask twice — and the
        // second answer is only kept if it is actually better, because a first read that
        // came back thin for some other reason is still the truthful one.
        if harvested.telemetry.isUnderfed,
           ChromiumAccessibility.isChromiumHost(
            processIdentifier: request.processIdentifier
           ) {
            ChromiumAccessibility.activate(processIdentifier: request.processIdentifier)
            try? await Task.sleep(for: ChromiumAccessibility.treeBuildDelay)
            let retried = harvestOnce(request, profile: profile)
            if retried.telemetry.harvestedProseLength
                > harvested.telemetry.harvestedProseLength {
                harvested = retried
            }
        }

        cache[key] = CachedHarvest(harvest: harvested, takenAt: clock.now, need: need)
        log(harvested.telemetry, for: request)
    }

    /// One prefetch harvest, from a reader built for it alone.
    ///
    /// Built fresh each time on purpose: a retry exists because the application may have
    /// rebuilt its tree in between, and every handle the previous reader interned
    /// describes the tree that has just been replaced.
    private func harvestOnce(
        _ request: Request,
        profile: ApplicationProfile
    ) -> ContextHarvest {
        let reader = LiveAccessibilityReader(
            root: request.element.element,
            primaryScreenMaxY: request.primaryScreenMaxY
        )
        return harvest(
            reader: reader,
            target: target(for: request, at: reader.rootReference),
            profile: profile,
            budget: ContextBudget(
                maximumRoundTrips: prefetchBudget.roundTrips,
                duration: prefetchBudget.duration
            )
        )
    }

    /// Drops what was learned about an application. Called when focus moves or the
    /// active application changes, because both mean the screen behind a cached harvest
    /// is no longer the one it described.
    func invalidate(processIdentifier: pid_t? = nil) {
        guard let processIdentifier else {
            cache.removeAll()
            return
        }
        cache = cache.filter { $0.key.processIdentifier != processIdentifier }
    }

    private func target(for request: Request, at element: ElementRef) -> ContextTarget {
        ContextTarget(
            element: element,
            applicationName: request.applicationName,
            bundleIdentifier: request.bundleIdentifier,
            targetKind: request.targetKind,
            capturedText: request.capturedText,
            targetRange: request.targetRange
        )
    }

    private func harvest(
        reader: LiveAccessibilityReader,
        target: ContextTarget,
        profile: ApplicationProfile,
        budget: ContextBudget
    ) -> ContextHarvest {
        pipeline.harvest(
            ContextWorkspace(
                reader: reader,
                budget: budget,
                target: target,
                profile: profile
            )
        )
    }

    /// The numbers the traversal used to gather and drop into a debug log where nobody
    /// could line them up against a disappointing suggestion.
    private func log(_ telemetry: ContextTelemetry, for request: Request) {
        logger.debug(
            """
            Context for \(request.applicationName, privacy: .public): \
            \(telemetry.roundTrips, privacy: .public) reads, \
            \(telemetry.nodesExamined, privacy: .public) nodes, \
            from [\(telemetry.contributingSources.joined(separator: ", "), privacy: .public)], \
            skipped [\(telemetry.skippedSources.joined(separator: ", "), privacy: .public)], \
            engine \(telemetry.engine?.rawValue ?? "none", privacy: .public), \
            prose \(telemetry.harvestedProseLength, privacy: .public)/\
            \(telemetry.requiredProseLength, privacy: .public)\
            \(telemetry.isUnderfed ? " — UNDERFED" : "", privacy: .public)\
            \(telemetry.wasTruncated ? " — truncated" : "", privacy: .public)
            """
        )
    }
}
