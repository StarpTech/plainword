import Foundation
import XCTest
@testable import PlainwordCore

final class ReadOnlyContextReceiptTests: XCTestCase {
    private func context(
        fragments: [ReadOnlyContextFragment] = [],
        leadingContext: String = "",
        trailingContext: String = ""
    ) -> TextEditContext {
        TextEditContext(
            text: "It works locally.",
            utf16Location: 0,
            utf16Length: 17,
            applicationContextFragments: fragments,
            leadingContext: leadingContext,
            trailingContext: trailingContext
        )
    }

    func testItemisesEveryFragmentInTheOrderTheModelReceivesThem() {
        let items = ReadOnlyContextReceipt.items(
            for: context(fragments: [
                .init(kind: .sourceApplication, text: "WhatsApp"),
                .init(kind: .fieldLabel, text: "Message"),
                .init(kind: .relatedPrecedingContent, text: "Atlas shipped yesterday.")
            ])
        )

        XCTAssertEqual(items.map(\.title), ["App", "Field label", "Text above"])
        XCTAssertEqual(items.map(\.detail), [
            "WhatsApp",
            "Message",
            "Atlas shipped yesterday."
        ])
        XCTAssertEqual(items.map(\.category), [.application, .field, .nearbyText])
    }

    func testSurroundingSentencesAreAccountedForToo() {
        let items = ReadOnlyContextReceipt.items(
            for: context(
                leadingContext: "The introduction is fine.",
                trailingContext: "The ending is fine."
            )
        )

        XCTAssertEqual(items.map(\.title), ["Around your text"])
        XCTAssertEqual(
            items.first?.detail,
            "The introduction is fine. … The ending is fine."
        )
    }

    func testSurroundingSentencesOnOneSideOnly() {
        let items = ReadOnlyContextReceipt.items(
            for: context(leadingContext: "The introduction is fine.")
        )
        XCTAssertEqual(items.first?.detail, "The introduction is fine.")
    }

    func testNothingIsClaimedWhenNothingIsSent() {
        XCTAssertTrue(ReadOnlyContextReceipt.items(for: context()).isEmpty)
    }

    func testDetailIsFlattenedToOneLine() {
        let items = ReadOnlyContextReceipt.items(
            for: context(fragments: [
                .init(kind: .relatedPrecedingContent, text: "Atlas\n shipped   yesterday.")
            ])
        )
        XCTAssertEqual(items.first?.detail, "Atlas shipped yesterday.")
    }

    /// A row truncates to fit and the tooltip shows the rest, so shortening here would
    /// put part of the account permanently out of reach.
    func testLongDetailIsKeptWholeSoItCanBeInspected() throws {
        let passage = String(repeating: "word ", count: 200)
        let items = ReadOnlyContextReceipt.items(
            for: context(fragments: [
                .init(kind: .relatedPrecedingContent, text: passage)
            ])
        )
        XCTAssertEqual(
            items.first?.detail,
            passage.trimmingCharacters(in: .whitespaces)
        )
    }

    func testItemIdentifiersAreStableAndDistinct() {
        let items = ReadOnlyContextReceipt.items(
            for: context(
                fragments: [
                    .init(kind: .sourceApplication, text: "Notes"),
                    .init(kind: .documentTitle, text: "Project Atlas")
                ],
                leadingContext: "Before."
            )
        )
        XCTAssertEqual(items.map(\.id), [0, 1, 2])
    }

    func testSummaryCarriesBothTheCountAndWhetherItLeftTheMachine() {
        XCTAssertEqual(
            ReadOnlyContextReceipt.summary(forItemCount: 0, wasAttached: false),
            "Nothing found nearby"
        )
        XCTAssertEqual(
            ReadOnlyContextReceipt.summary(forItemCount: 1, wasAttached: false),
            "1 thing found nearby — not attached"
        )
        XCTAssertEqual(
            ReadOnlyContextReceipt.summary(forItemCount: 4, wasAttached: true),
            "4 things found nearby — attached"
        )
    }
}
