import XCTest
@testable import PlainwordCore

final class WritingSuggestionTests: XCTestCase {
    func testClassifiesSmallWordChangesAsCorrection() throws {
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.make(
                originalText: "I definately sent it tommorow.",
                replacementText: "I definitely sent it tomorrow."
            )
        )

        XCTAssertEqual(suggestion.kind, .correction)
        XCTAssertEqual(
            suggestion.changes,
            [
                WritingTextChange(original: "definately", replacement: "definitely"),
                WritingTextChange(original: "tommorow", replacement: "tomorrow")
            ]
        )
    }

    func testComposedDraftIsAWholeInsertion() throws {
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.makeComposition(
                "  Running about ten minutes late, sorry.  "
            )
        )

        XCTAssertEqual(suggestion.kind, .composition)
        XCTAssertEqual(suggestion.originalText, "")
        XCTAssertEqual(
            suggestion.replacementText,
            "Running about ten minutes late, sorry."
        )
        XCTAssertEqual(
            suggestion.changes,
            [
                WritingTextChange(
                    original: "",
                    replacement: "Running about ten minutes late, sorry."
                )
            ]
        )
    }

    func testComposedDraftNeedsSomethingToInsert() {
        XCTAssertNil(WritingSuggestionPlanner.makeComposition("   \n "))
        XCTAssertNil(WritingSuggestionPlanner.makeComposition(""))
    }

    func testComposedDraftKeepsDetailAndLanguageAnEditWouldRefuse() throws {
        // `make` rejects both of these on an edit, where they would mean the model
        // invented facts or switched language. Writing new text is where they belong.
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.makeComposition("Bin zehn Minuten später da, ab 14:30.")
        )

        XCTAssertEqual(suggestion.kind, .composition)
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "",
                replacementText: "Bin zehn Minuten später da, ab 14:30."
            )
        )
    }

    func testClassifiesShortAppendOnlySuggestionAsCompletion() throws {
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.make(
                originalText: "I really apprecia",
                replacementText: "I really appreciate it."
            )
        )

        XCTAssertEqual(suggestion.kind, .completion)
        XCTAssertEqual(
            suggestion.changes,
            [WritingTextChange(original: "", replacement: "te it.")]
        )
    }

    func testRejectsCompletionWhenItIsNotStructurallyAllowed() {
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "I really apprecia",
                replacementText: "I really appreciate it.",
                completionIsAllowed: false
            )
        )
    }

    func testRejectsLongOrMultilineCompletion() {
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "I think",
                replacementText: "I think one two three four five six seven eight nine"
            )
        )
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "I think",
                replacementText: "I think this.\nAnd that."
            )
        )
    }

    func testClassifiesBroadChangeAsRewrite() throws {
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.make(
                originalText: "Launch maybe not happen because vendor and timeline issue.",
                replacementText: "The launch may not happen because of vendor and timeline issues."
            )
        )

        XCTAssertEqual(suggestion.kind, .rewrite)
    }

    func testKeepsFocusedModelCorrectionAsCorrection() throws {
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.make(
                originalText: "It's defintlys great ot have you",
                replacementText: "It's definitely great to have you.",
                classifiedAs: .correction
            )
        )

        XCTAssertEqual(suggestion.kind, .correction)
        XCTAssertEqual(suggestion.changes.count, 3)
    }

    func testPromotesDistributedModelCorrectionToRewrite() throws {
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.make(
                originalText: "btw how is your daughter all good?",
                replacementText: "By the way, how is your daughter? All good?",
                classifiedAs: .correction
            )
        )

        XCTAssertGreaterThan(suggestion.changes.count, 3)
        XCTAssertEqual(suggestion.kind, .rewrite)
    }

    func testPromotesSentenceWideModelCorrectionToRewrite() throws {
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.make(
                originalText: "Launch maybe not happen because vendor and timeline issue.",
                replacementText: "The launch may not happen because of vendor and timeline issues.",
                classifiedAs: .correction
            )
        )

        XCTAssertEqual(suggestion.kind, .rewrite)
    }

    func testRejectsStructurallyInvalidModelCompletion() {
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "This is wrong.",
                replacementText: "This is correct.",
                classifiedAs: .completion
            )
        )
    }

    func testRejectsInventedConcreteDetail() {
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "I will send it soon.",
                replacementText: "I will send it on Friday."
            )
        )
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "The total is ready.",
                replacementText: "The total is 42."
            )
        )
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "You can find it online.",
                replacementText: "You can find it at https://example.com."
            )
        )
    }

    func testCustomEditMayApplyExplicitConcreteDetail() throws {
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.make(
                originalText: "I will send it soon.",
                replacementText: "I will send it on Friday.",
                classifiedAs: .rewrite,
                allowsNewConcreteDetails: true
            )
        )

        XCTAssertEqual(suggestion.replacementText, "I will send it on Friday.")
    }

    func testRejectsUnsolicitedLanguageChange() {
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "Thats funny",
                replacementText: "Das ist lustig.",
                classifiedAs: .rewrite
            )
        )
    }

    func testCustomEditMayExplicitlyChangeLanguage() throws {
        let suggestion = try XCTUnwrap(
            WritingSuggestionPlanner.make(
                originalText: "Thats funny",
                replacementText: "Das ist lustig.",
                classifiedAs: .rewrite,
                allowsLanguageChange: true
            )
        )

        XCTAssertEqual(suggestion.replacementText, "Das ist lustig.")
    }

    func testReturnsNilForUnchangedText() {
        XCTAssertNil(
            WritingSuggestionPlanner.make(
                originalText: "Already clear.",
                replacementText: "Already clear."
            )
        )
    }
}
