import XCTest
@testable import PlainwordCore

final class EditRequestPolicyTests: XCTestCase {
    func testClassifiesTextBoundariesAndDeletion() {
        XCTAssertEqual(classify(characters: "a"), .insertedText)
        XCTAssertEqual(classify(characters: " "), .wordBoundary)
        XCTAssertEqual(classify(characters: "."), .sentenceBoundary)
        XCTAssertEqual(classify(characters: nil, specialKey: .enter), .sentenceBoundary)
        XCTAssertEqual(classify(characters: nil, specialKey: .deletion), .deletion)
    }

    func testClassifiesSupportedEditingShortcuts() {
        XCTAssertEqual(classify(command: true, ignoringModifiers: "v"), .paste)
        XCTAssertEqual(classify(command: true, ignoringModifiers: "x"), .cut)
        XCTAssertEqual(classify(command: true, ignoringModifiers: "z"), .cancelOnly)
        XCTAssertEqual(classify(command: true, ignoringModifiers: "c"), .ignored)
    }

    func testNavigationCancelsWithoutSchedulingWork() {
        XCTAssertEqual(classify(characters: nil, specialKey: .other), .cancelOnly)
        XCTAssertNil(EditTrigger.cancelOnly.debounceMilliseconds)
        XCTAssertNil(EditTrigger.ignored.debounceMilliseconds)
    }

    func testUsesTriggerSpecificDebounces() {
        XCTAssertEqual(EditTrigger.wordBoundary.debounceMilliseconds, 250)
        XCTAssertEqual(EditTrigger.sentenceBoundary.debounceMilliseconds, 400)
        XCTAssertEqual(EditTrigger.insertedText.debounceMilliseconds, 900)
    }

    func testParagraphReviewDoesNotDependOnFinalWordSpellingSignal() {
        XCTAssertEqual(
            EditRequestRouter.decision(
                for: .insertedText,
                targetKind: .paragraph,
                completionIsAllowed: false,
                currentWordIsSuspicious: false,
                wordCount: 20
            ),
            .immediate(.correct)
        )
        XCTAssertEqual(
            EditRequestRouter.decision(
                for: .wordBoundary,
                targetKind: .paragraph,
                completionIsAllowed: false,
                currentWordIsSuspicious: false,
                wordCount: 20
            ),
            .delayed(.correct, additionalMilliseconds: 650)
        )
    }

    func testExtractsWordAtOrBeforeUTF16Caret() {
        let text = "Hello 👨‍👩‍👧‍👦 wokr later"
        let caret = NSMaxRange((text as NSString).range(of: "wokr"))

        XCTAssertEqual(
            LocalTextSignals.wordAtOrBeforeCaret(in: text, caretUTF16Offset: caret),
            "wokr"
        )
        XCTAssertEqual(LocalTextSignals.wordCount(in: text), 3)
    }

    func testRoutesSuspiciousWordImmediately() {
        XCTAssertEqual(
            EditRequestRouter.decision(
                for: .wordBoundary,
                targetKind: .sentence,
                completionIsAllowed: true,
                currentWordIsSuspicious: true,
                wordCount: 3
            ),
            .immediate(.correctOrComplete)
        )
    }

    func testDelaysCompletionAfterCleanTrailingSpace() {
        XCTAssertEqual(
            EditRequestRouter.decision(
                for: .wordBoundary,
                targetKind: .sentence,
                completionIsAllowed: true,
                currentWordIsSuspicious: false,
                wordCount: 3
            ),
            .delayed(.correctOrComplete, additionalMilliseconds: 650)
        )
    }

    func testSkipsOrdinaryCompletedWordWhenCompletionIsUnavailable() {
        XCTAssertEqual(
            EditRequestRouter.decision(
                for: .wordBoundary,
                targetKind: .sentence,
                completionIsAllowed: false,
                currentWordIsSuspicious: false,
                wordCount: 3
            ),
            .none
        )
    }

    private func classify(
        characters: String? = nil,
        specialKey: EditSpecialKey? = nil,
        command: Bool = false,
        control: Bool = false,
        ignoringModifiers: String? = nil
    ) -> EditTrigger {
        EditTriggerClassifier.classify(
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers,
            specialKey: specialKey,
            hasCommand: command,
            hasControl: control
        )
    }
}
