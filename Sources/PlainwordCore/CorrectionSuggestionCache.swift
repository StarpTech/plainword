import Foundation

/// Identity of a correction request for caching purposes.
///
/// The edit target is matched exactly, because the suggestion is spliced back over it.
/// Everything around the target is matched by digest instead: read-only context is
/// re-harvested from a live screen on every request and varies in ways that do not change
/// what the model was asked, so an exact match would discard usable entries constantly.
/// See `ReadOnlyContextDigest`.
public struct CorrectionCacheKey: Hashable, Sendable {
    public let endpoint: String
    public let model: String
    public let locale: String
    public let tone: String
    public let style: String
    public let thinkingMode: String
    public let intent: EditIntent
    public let targetKind: TextEditTargetKind
    public let text: String
    public let applicationContextDigest: String
    public let leadingContextDigest: String
    public let trailingContextDigest: String

    public init(
        endpoint: String,
        model: String,
        locale: String,
        tone: String,
        style: String,
        thinkingMode: String,
        intent: EditIntent,
        context: TextEditContext
    ) {
        self.endpoint = endpoint
        self.model = model
        self.locale = locale
        self.tone = tone
        self.style = style
        self.thinkingMode = thinkingMode
        self.intent = intent
        self.targetKind = context.targetKind
        self.text = context.text
        self.applicationContextDigest = ReadOnlyContextDigest.value(
            for: context.applicationContextFragments
        )
        self.leadingContextDigest = ReadOnlyContextDigest.value(
            for: context.leadingContext,
            retaining: .end
        )
        self.trailingContextDigest = ReadOnlyContextDigest.value(
            for: context.trailingContext,
            retaining: .start
        )
    }
}

public enum CachedCorrection: Equatable, Sendable {
    case unchanged
    case suggestion(WritingSuggestion)
}

public struct CorrectionSuggestionCache: Sendable {
    private struct Entry: Sendable {
        let value: CachedCorrection
        let expiresAt: Date
    }

    private let capacity: Int
    private let timeToLive: TimeInterval
    private var entries: [CorrectionCacheKey: Entry] = [:]
    private var order: [CorrectionCacheKey] = []

    public init(capacity: Int = 128, timeToLive: TimeInterval = 10 * 60) {
        self.capacity = max(1, capacity)
        self.timeToLive = max(1, timeToLive)
    }

    public mutating func value(
        for key: CorrectionCacheKey,
        now: Date = Date()
    ) -> CachedCorrection? {
        purgeExpired(now: now)
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    public mutating func insert(
        _ value: CachedCorrection,
        for key: CorrectionCacheKey,
        now: Date = Date()
    ) {
        purgeExpired(now: now)
        entries[key] = Entry(
            value: value,
            expiresAt: now.addingTimeInterval(timeToLive)
        )
        touch(key)

        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    private mutating func touch(_ key: CorrectionCacheKey) {
        order.removeAll(where: { $0 == key })
        order.append(key)
    }

    private mutating func purgeExpired(now: Date) {
        let expiredKeys = entries.compactMap { key, entry in
            entry.expiresAt <= now ? key : nil
        }
        guard !expiredKeys.isEmpty else { return }
        let expired = Set(expiredKeys)
        for key in expired {
            entries.removeValue(forKey: key)
        }
        order.removeAll(where: expired.contains)
    }
}
