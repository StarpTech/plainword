import Foundation

/// The allowance for one context assembly, spent by its sources in tier order.
///
/// Counted in round trips as well as wall clock. Either alone misleads: a stalled
/// application burns the clock without making progress, while a responsive one can
/// answer hundreds of calls inside a few milliseconds and should be allowed to.
///
/// Sharing one budget across the sources is the point. The traversal this replaces was
/// the only thing spending, so nothing pressed it to be cheap; here a source that reads
/// widely leaves less for the ones after it, and the last one may find nothing left.
public final class ContextBudget {
    public let maximumRoundTrips: Int
    private let deadline: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    public private(set) var spentRoundTrips = 0
    public private(set) var reachedRoundTripLimit = false
    public private(set) var reachedTimeLimit = false

    /// A budget with no deadline, for tests and for offline replay where wall clock
    /// means nothing.
    public init(maximumRoundTrips: Int) {
        self.maximumRoundTrips = max(0, maximumRoundTrips)
        self.deadline = nil
    }

    public init(maximumRoundTrips: Int, duration: Duration) {
        self.maximumRoundTrips = max(0, maximumRoundTrips)
        self.deadline = ContinuousClock().now.advanced(by: duration)
    }

    public var remainingRoundTrips: Int {
        max(0, maximumRoundTrips - spentRoundTrips)
    }

    public var isExhausted: Bool {
        if spentRoundTrips >= maximumRoundTrips {
            reachedRoundTripLimit = true
            return true
        }
        if let deadline, clock.now >= deadline {
            reachedTimeLimit = true
            return true
        }
        return false
    }

    /// Records one round trip. Returns false when the allowance is already gone, which
    /// is the caller's signal to stop rather than to try anyway.
    @discardableResult
    public func charge() -> Bool {
        guard !isExhausted else { return false }
        spentRoundTrips += 1
        return true
    }
}

/// What one assembly actually managed to do, for diagnosing a thin result.
///
/// The traversal this replaces gathered the same numbers and sent them to a debug log,
/// where nobody could correlate them with a disappointing suggestion. These travel with
/// the result instead.
public struct ContextTelemetry: Equatable, Sendable {
    public var roundTrips = 0
    public var reachedRoundTripLimit = false
    public var reachedTimeLimit = false
    public var nodesExamined = 0
    /// Which sources contributed at least one candidate, in the order they ran.
    public var contributingSources: [String] = []
    /// Sources that were never reached because the need was already met.
    public var skippedSources: [String] = []
    public var satisfiedAfterTier: ContextTier?

    public init() {}

    public var wasTruncated: Bool { reachedRoundTripLimit || reachedTimeLimit }
}
