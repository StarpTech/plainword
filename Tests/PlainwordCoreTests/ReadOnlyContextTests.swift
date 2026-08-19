import Foundation
import XCTest
@testable import PlainwordCore

final class ReadOnlyContextTests: XCTestCase {
    func testRanksSemanticContextBeforeNearbyContentAndRestoresPresentationOrder() {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(
                    kind: .relatedPrecedingContent,
                    text: "Most recent message",
                    relevance: 650,
                    readingOrder: 20
                ),
                .init(
                    kind: .fieldLabel,
                    text: "Reply",
                    relevance: 1_000,
                    readingOrder: 0
                ),
                .init(
                    kind: .relatedPrecedingContent,
                    text: "Earlier message",
                    relevance: 500,
                    readingOrder: 10
                )
            ],
            maximumUTF16Length: 100
        )

        XCTAssertEqual(selected.map(\.kind), [
            .fieldLabel,
            .relatedPrecedingContent,
            .relatedPrecedingContent
        ])
        XCTAssertEqual(selected.map(\.text), [
            "Reply",
            "Earlier message",
            "Most recent message"
        ])
    }

    func testRejectsLowConfidenceDuplicatesAndEditableTextAggregates() {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(
                    kind: .relatedContent,
                    text: "Navigation",
                    relevance: 100,
                    readingOrder: 0
                ),
                .init(
                    kind: .relatedPrecedingContent,
                    text: "Please review this complete draft plus surrounding text",
                    relevance: 700,
                    readingOrder: 1
                ),
                .init(
                    kind: .fieldLabel,
                    text: "Reply",
                    relevance: 1_000,
                    readingOrder: 2
                ),
                .init(
                    kind: .fieldLabel,
                    text: "  Reply  ",
                    relevance: 900,
                    readingOrder: 3
                )
            ],
            excluding: ["Please review this complete draft"],
            maximumUTF16Length: 100
        )

        XCTAssertEqual(selected, [.init(kind: .fieldLabel, text: "Reply")])
    }

    func testTruncatesPrecedingContentFromTheNearestEndWithoutSplittingEmoji() throws {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(
                    kind: .relatedPrecedingContent,
                    text: "abcdefgh🙂",
                    relevance: 700,
                    readingOrder: 0
                )
            ],
            maximumUTF16Length: 3
        )

        XCTAssertEqual(try XCTUnwrap(selected.first).text, "h🙂")
    }

    func testKeepsHighestConfidenceVersionOfDuplicateCandidate() {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(
                    kind: .fieldDescription,
                    text: "Reply",
                    relevance: 500,
                    readingOrder: 0
                ),
                .init(
                    kind: .fieldLabel,
                    text: "Reply",
                    relevance: 1_000,
                    readingOrder: 1
                )
            ],
            maximumUTF16Length: 100
        )

        XCTAssertEqual(selected, [.init(kind: .fieldLabel, text: "Reply")])
    }

    func testLargeFragmentDoesNotConsumeTheEntireContextBudget() {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(
                    kind: .relatedPrecedingContent,
                    text: String(repeating: "a", count: 2_000),
                    relevance: 800,
                    readingOrder: 0
                ),
                .init(
                    kind: .documentTitle,
                    text: "Project Atlas",
                    relevance: 700,
                    readingOrder: 1
                )
            ],
            maximumUTF16Length: 1_200
        )

        XCTAssertEqual(selected.map(\.kind), [.documentTitle, .relatedPrecedingContent])
        XCTAssertEqual(selected.first?.text, "Project Atlas")
        XCTAssertEqual(selected.last.map { ($0.text as NSString).length }, 900)
    }

    func testPresentsFieldIdentityBeforeLowConfidenceFieldHelp() {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(
                    kind: .fieldHelp,
                    text: "Press Return to send",
                    relevance: 310,
                    readingOrder: 0
                ),
                .init(
                    kind: .fieldIdentity,
                    text: "Reply to Jamie",
                    relevance: 950,
                    readingOrder: 0
                )
            ],
            maximumUTF16Length: 100
        )

        XCTAssertEqual(selected, [
            .init(kind: .fieldIdentity, text: "Reply to Jamie"),
            .init(kind: .fieldHelp, text: "Press Return to send")
        ])
    }

    func testPresentsSourceApplicationAsMetadataBeforeContent() {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(
                    kind: .fieldLabel,
                    text: "Reply",
                    relevance: 1_000,
                    readingOrder: 0
                ),
                .init(
                    kind: .sourceApplication,
                    text: "Mail",
                    relevance: 1_000,
                    readingOrder: 0
                )
            ],
            maximumUTF16Length: 100
        )

        XCTAssertEqual(selected, [
            .init(kind: .sourceApplication, text: "Mail"),
            .init(kind: .fieldLabel, text: "Reply")
        ])
    }

    func testMarksWherePrecedingContentWasRankedOut() {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(kind: .relatedPrecedingContent, text: "The oldest message", relevance: 700, readingOrder: 10),
                .init(kind: .relatedPrecedingContent, text: "A middle message", relevance: 400, readingOrder: 20),
                .init(kind: .relatedPrecedingContent, text: "The newest message", relevance: 800, readingOrder: 30)
            ],
            maximumUTF16Length: 100,
            maximumFragments: 2
        )

        XCTAssertEqual(selected.map(\.text), [
            "The oldest message",
            "\(ReadOnlyContextRanker.elisionMarker) The newest message"
        ])
    }

    func testDoesNotMarkPrecedingContentThatStayedContiguous() {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(kind: .relatedPrecedingContent, text: "The older message", relevance: 700, readingOrder: 10),
                .init(kind: .relatedPrecedingContent, text: "The newer message", relevance: 800, readingOrder: 20)
            ],
            maximumUTF16Length: 100
        )

        XCTAssertEqual(selected.map(\.text), ["The older message", "The newer message"])
    }

    func testDoesNotMarkGapsBetweenUnrelatedKinds() {
        let selected = ReadOnlyContextRanker.select(
            from: [
                .init(kind: .fieldLabel, text: "Reply", relevance: 1_000, readingOrder: 10),
                .init(kind: .fieldLabel, text: "Draft label", relevance: 400, readingOrder: 20),
                .init(kind: .fieldLabel, text: "Recipient", relevance: 900, readingOrder: 30)
            ],
            maximumUTF16Length: 100,
            maximumFragments: 2
        )

        XCTAssertEqual(selected.map(\.text), ["Reply", "Recipient"])
    }
}
