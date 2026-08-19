import XCTest
@testable import PlainwordCore

final class SpellingLanguageSettingsTests: XCTestCase {
    func testDetectsLanguageFromTextWindow() {
        XCTAssertEqual(
            TextLanguageDetector.dominantLanguageIdentifier(
                in: "This is a short sentence with one obvious typo in the wokr."
            ),
            "en"
        )
        XCTAssertEqual(
            TextLanguageDetector.dominantLanguageIdentifier(
                in: "Das ist ein kurzer deutscher Satz mit genügend Kontext."
            ),
            "de"
        )
    }

    func testSkipsShortOrUncertainText() {
        XCTAssertNil(TextLanguageDetector.dominantLanguageIdentifier(in: "wokr"))
        XCTAssertNil(TextLanguageDetector.dominantLanguageIdentifier(in: "12345"))
    }

    func testUsesSurroundingContextForLanguageDetection() {
        let context = TextEditContext(
            text: "wokr",
            utf16Location: 32,
            utf16Length: 4,
            leadingContext: "This is enough English context. ",
            trailingContext: ""
        )

        XCTAssertEqual(
            TextLanguageDetector.dominantLanguageIdentifier(in: context),
            "en"
        )
    }

    func testEditableTextWinsOverApplicationLanguage() {
        let context = TextEditContext(
            text: "Thats funny",
            utf16Location: 0,
            utf16Length: 11,
            applicationContext: "Das ist eine deutsche App mit Einstellungen und Hilfetexten."
        )

        XCTAssertEqual(
            TextLanguageDetector.dominantLanguageIdentifier(in: context),
            "en"
        )
    }

    func testDoesNotUseApplicationUIContextAsLanguageEvidence() {
        let context = TextEditContext(
            text: "wokr",
            utf16Location: 0,
            utf16Length: 4,
            applicationContext: "Das ist eine deutsche App mit Einstellungen und Hilfetexten."
        )

        XCTAssertNil(TextLanguageDetector.dominantLanguageIdentifier(in: context))
    }

    func testResolvesExactAndBaseLanguageDictionaries() {
        let available = ["en", "en_GB", "de", "pt_BR", "pt_PT"]

        XCTAssertEqual(
            SpellingDictionaryResolver.resolve(
                languageIdentifier: "en-GB",
                availableLanguages: available
            ),
            "en_GB"
        )
        XCTAssertEqual(
            SpellingDictionaryResolver.resolve(
                languageIdentifier: "de-DE",
                availableLanguages: available
            ),
            "de"
        )
        XCTAssertEqual(
            SpellingDictionaryResolver.resolve(
                languageIdentifier: "pt",
                availableLanguages: available,
                preferredLocaleIdentifier: "pt-PT"
            ),
            "pt_PT"
        )
    }

    func testUnsupportedLanguageHasNoDictionaryFallback() {
        XCTAssertNil(
            SpellingDictionaryResolver.resolve(
                languageIdentifier: "ja",
                availableLanguages: ["en", "de", "fr"]
            )
        )
        XCTAssertNil(
            SpellingDictionaryResolver.resolve(
                languageIdentifier: nil,
                availableLanguages: ["en", "de", "fr"]
            )
        )
    }
}
