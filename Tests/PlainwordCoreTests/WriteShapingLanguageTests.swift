import Foundation
@testable import PlainwordCore
import XCTest

/// The write shaping is the same code for every script, so what these check is that it
/// never spells a range in a way only English survives: never inside a character built
/// from several UTF-16 units, never assuming a space marks a word, and never assuming a
/// line ends with a line feed.
final class WriteShapingLanguageTests: XCTestCase {
    private func assertSpanRebuildsText(
        original: String,
        replacement: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let span = TextSpanNarrowing.narrow(
            original: original,
            replacement: replacement
        ) else {
            return XCTFail("Expected a changed span", file: file, line: line)
        }
        let source = original as NSString
        // A range that splits a character would not survive this: composing it outwards
        // would widen it. An insertion has no width to widen, so what is checked there
        // is that it sits where a character begins, since composing a point inside one
        // would answer with the whole character around it.
        let composed = source.rangeOfComposedCharacterSequences(for: span.originalUTF16Range)
        if span.originalUTF16Range.length == 0 {
            XCTAssertEqual(
                composed.location,
                span.originalUTF16Range.location,
                file: file,
                line: line
            )
        } else {
            XCTAssertEqual(composed, span.originalUTF16Range, file: file, line: line)
        }
        XCTAssertEqual(
            source.substring(with: span.originalUTF16Range),
            span.originalText,
            file: file,
            line: line
        )
        XCTAssertEqual(
            source.replacingCharacters(in: span.originalUTF16Range, with: span.replacement),
            replacement,
            file: file,
            line: line
        )
    }

    func testGermanCompoundCorrection() {
        assertSpanRebuildsText(
            original: "Vielen dank für die Zusammenarbeit gestern.",
            replacement: "Vielen Dank für die Zusammenarbeit gestern."
        )
    }

    func testFrenchAccentAddedToAWord() {
        assertSpanRebuildsText(
            original: "Je vous remercie de votre reponse rapide.",
            replacement: "Je vous remercie de votre réponse rapide."
        )
    }

    func testCombiningAccentIsNeverSplit() {
        assertSpanRebuildsText(
            original: "une reponse tre\u{0301}s claire",
            replacement: "une réponse tre\u{0301}s longue"
        )
    }

    func testJapaneseHasNoWordSpacesToLeanOn() {
        assertSpanRebuildsText(
            original: "昨日はお世話になりまた。",
            replacement: "昨日はお世話になりました。"
        )
    }

    func testArabicIsAddressedInLogicalOrder() {
        let original = "شكرا لك على مساعدتك امس."
        let replacement = "شكرا لك على مساعدتك أمس."
        assertSpanRebuildsText(original: original, replacement: replacement)

        // Logical order, not visual: the span sits where the change is in the string.
        let span = TextSpanNarrowing.narrow(original: original, replacement: replacement)
        XCTAssertEqual(span?.originalText, "ا")
        XCTAssertEqual(span?.replacement, "أ")
    }

    func testHebrewWithVowelPointsKeepsThePointsWithTheirLetters() {
        assertSpanRebuildsText(
            original: "שָׁלוֹם רב, תודה על העזרה",
            replacement: "שָׁלוֹם רב, תודה רבה על העזרה"
        )
    }

    func testDevanagariClusterIsOneCharacter() {
        assertSpanRebuildsText(
            original: "नमस्ते, कल की मदद के लिए धन्यवाद",
            replacement: "नमस्ते, कल की सहायता के लिए धन्यवाद"
        )
    }

    func testEmojiSequenceIsNeverCutInHalf() {
        assertSpanRebuildsText(
            original: "Great news 👨‍👩‍👧‍👦 for everyone",
            replacement: "Great news 👨‍👩‍👧‍👦 for everybody"
        )
    }

    func testThaiHasNoSpacesBetweenWords() {
        assertSpanRebuildsText(
            original: "ขอบคุณสำหรับความช่วยเหลือ",
            replacement: "ขอบคุณมากสำหรับความช่วยเหลือ"
        )
    }

    func testCanonicallyEquivalentTextIsNotAChange() {
        // Precomposed against decomposed: the same writing, so there is nothing to
        // write, and the caller is expected to leave the field alone.
        XCTAssertNil(
            TextSpanNarrowing.narrow(original: "café", replacement: "cafe\u{0301}")
        )
    }

    func testParagraphSeparatorCountsAsALineBreak() {
        let edits = LineSegmentedEditPlanner.plan(
            original: "Erste Zeile.\u{2029}zweite zeile.",
            replacement: "Erste Zeile.\u{2029}Zweite Zeile."
        )

        XCTAssertEqual(edits?.count, 1)
        XCTAssertEqual(edits?.first?.replacement, "Zweite Zeile.")
    }

    func testJapaneseParagraphsArePlannedLineByLine() {
        let original = "山田様\n\nお世話になっており。\n\n田中"
        let corrected = "山田様\n\nお世話になっております。\n\n田中"

        guard let span = TextSpanNarrowing.narrow(
            original: original,
            replacement: corrected
        ) else {
            return XCTFail("Expected a changed span")
        }
        // The greeting and the sign-off are outside the span, so no write reaches them.
        XCTAssertFalse(span.originalText.contains("山田様"))
        XCTAssertFalse(span.originalText.contains("田中"))
        XCTAssertFalse(span.originalText.contains(where: \.isNewline))
    }
}
