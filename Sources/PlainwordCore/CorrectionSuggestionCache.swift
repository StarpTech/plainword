import Foundation

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
    public let applicationContext: String
    public let applicationContextFragments: [ReadOnlyContextFragment]
    public let leadingContext: String
    public let trailingContext: String

    public init(
        endpoint: String,
        model: String,
        locale: String,
        tone: String,
        style: String,
        thinkingMode: String,
        intent: EditIntent,
        targetKind: TextEditTargetKind,
        text: String,
        applicationContext: String = "",
        applicationContextFragments: [ReadOnlyContextFragment] = [],
        leadingContext: String,
        trailingContext: String
    ) {
        self.endpoint = endpoint
        self.model = model
        self.locale = locale
        self.tone = tone
        self.style = style
        self.thinkingMode = thinkingMode
        self.intent = intent
        self.targetKind = targetKind
        self.text = text
        self.applicationContext = applicationContext
        self.applicationContextFragments = applicationContextFragments
        self.leadingContext = leadingContext
        self.trailingContext = trailingContext
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
