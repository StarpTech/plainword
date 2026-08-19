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

    func testExpiresEntriesAndEvictsLeastRecentlyUsedEntry() {
        let start = Date(timeIntervalSince1970: 1_000)
        var expiring = CorrectionSuggestionCache(capacity: 2, timeToLive: 5)
        expiring.insert(.unchanged, for: key(text: "old"), now: start)
        XCTAssertNil(
            expiring.value(
                for: key(text: "old"),
                now: start.addingTimeInterval(6)
            )
        )

        var bounded = CorrectionSuggestionCache(capacity: 1)
        bounded.insert(.unchanged, for: key(text: "first"), now: start)
        bounded.insert(.unchanged, for: key(text: "second"), now: start)
        XCTAssertNil(bounded.value(for: key(text: "first"), now: start))
        XCTAssertEqual(bounded.value(for: key(text: "second"), now: start), .unchanged)
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
