import Foundation
import XCTest
@testable import PlainwordCore

final class CorrectionSuggestionCacheTests: XCTestCase {
    func testCachesSuggestionAndUnchangedResults() {
        var cache = CorrectionSuggestionCache()
        let suggestion = WritingSuggestion(
            kind: .correction,
            originalText: "wokr",
            replacementText: "work",
            changes: [.init(original: "wokr", replacement: "work")]
        )

        cache.insert(.suggestion(suggestion), for: key(text: "wokr"))
        cache.insert(.unchanged, for: key(text: "work"))

        XCTAssertEqual(cache.value(for: key(text: "wokr")), .suggestion(suggestion))
        XCTAssertEqual(cache.value(for: key(text: "work")), .unchanged)
    }

    func testExpiresEntriesAtTheTimeToLiveBoundary() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = CorrectionSuggestionCache(capacity: 2, timeToLive: 5)
        cache.insert(.unchanged, for: key(text: "old"), now: start)

        XCTAssertEqual(
            cache.value(
                for: key(text: "old"),
                now: start.addingTimeInterval(4.999)
            ),
            .unchanged
        )
        XCTAssertNil(
            cache.value(
                for: key(text: "old"),
                now: start.addingTimeInterval(5)
            )
        )
    }

    func testEvictsLeastRecentlyUsedEntry() {
        let now = Date(timeIntervalSince1970: 1_000)
        var cache = CorrectionSuggestionCache(capacity: 2)
        let first = key(text: "first")
        let second = key(text: "second")
        let third = key(text: "third")

        cache.insert(.unchanged, for: first, now: now)
        cache.insert(.unchanged, for: second, now: now)
        XCTAssertEqual(cache.value(for: first, now: now), .unchanged)
        cache.insert(.unchanged, for: third, now: now)

        XCTAssertEqual(cache.value(for: first, now: now), .unchanged)
        XCTAssertNil(cache.value(for: second, now: now))
        XCTAssertEqual(cache.value(for: third, now: now), .unchanged)
    }

    func testReplacingEntryRefreshesItsValueAndExpiry() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = CorrectionSuggestionCache(timeToLive: 5)
        let cacheKey = key(text: "wokr")
        let suggestion = WritingSuggestion(
            kind: .correction,
            originalText: "wokr",
            replacementText: "work",
            changes: [.init(original: "wokr", replacement: "work")]
        )

        cache.insert(.unchanged, for: cacheKey, now: start)
        cache.insert(
            .suggestion(suggestion),
            for: cacheKey,
            now: start.addingTimeInterval(4)
        )

        XCTAssertEqual(
            cache.value(for: cacheKey, now: start.addingTimeInterval(8)),
            .suggestion(suggestion)
        )
        XCTAssertNil(
            cache.value(for: cacheKey, now: start.addingTimeInterval(9))
        )
    }

    func testApplicationContextIsPartOfCacheIdentity() {
        var cache = CorrectionSuggestionCache()
        cache.insert(
            .unchanged,
            for: key(text: "It works locally.", applicationContext: "Plainword")
        )

        XCTAssertNil(
            cache.value(
                for: key(text: "It works locally.", applicationContext: "Grammarly")
            )
        )
    }

    func testApplicationContextProvenanceIsPartOfCacheIdentity() {
        var cache = CorrectionSuggestionCache()
        cache.insert(
            .unchanged,
            for: key(
                text: "It works locally.",
                applicationContext: "Project Atlas",
                applicationContextFragments: [
                    .init(kind: .documentTitle, text: "Project Atlas")
                ]
            )
        )

        XCTAssertNil(
            cache.value(
                for: key(
                    text: "It works locally.",
                    applicationContext: "Project Atlas",
                    applicationContextFragments: [
                        .init(kind: .fieldDescription, text: "Project Atlas")
                    ]
                )
            )
        )
    }

    private func key(
        text: String,
        applicationContext: String = "",
        applicationContextFragments: [ReadOnlyContextFragment] = []
    ) -> CorrectionCacheKey {
        CorrectionCacheKey(
            endpoint: "https://example.com/v1/chat/completions",
            model: "fast-model",
            locale: "en-US",
            tone: "neutral",
            style: "clear",
            thinkingMode: "low",
            intent: .correct,
            targetKind: .sentence,
            text: text,
            applicationContext: applicationContext,
            applicationContextFragments: applicationContextFragments,
            leadingContext: "",
            trailingContext: ""
        )
    }
}
