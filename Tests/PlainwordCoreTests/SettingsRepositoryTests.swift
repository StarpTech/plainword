import Foundation
import XCTest
@testable import PlainwordCore

final class SettingsRepositoryTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PlainwordTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsArePrivacyPreserving() {
        let repository = SettingsRepository(suiteName: suiteName)

        XCTAssertEqual(repository.profile, WritingProfile())
        XCTAssertEqual(repository.llmSettings, LLMSettings())
        XCTAssertEqual(
            repository.spellingLanguageSettings,
            SpellingLanguageSettings()
        )
    }

    func testProfileAndSettingsRoundTrip() {
        let repository = SettingsRepository(suiteName: suiteName)
        repository.profile = WritingProfile(
            tone: .friendly,
            style: .conversational,
            promptExtension: "Prefer British English."
        )
        repository.llmSettings = LLMSettings(
            provider: .ollama,
            endpoint: "  https://example.com/v1/chat/completions  ",
            model: " example-model ",
            ollamaModel: " qwen3:8b ",
            codexModel: " gpt-5.6-terra ",
            authentication: .customHeader,
            customHeaderName: " api-key ",
            thinkingMode: .medium
        )
        repository.spellingLanguageSettings = SpellingLanguageSettings(
            mode: .fixed,
            fixedLanguageIdentifier: "de"
        )
        let reloaded = SettingsRepository(suiteName: suiteName)
        XCTAssertEqual(
            reloaded.profile,
            WritingProfile(
                tone: .friendly,
                style: .conversational,
                promptExtension: "Prefer British English."
            )
        )
        XCTAssertEqual(
            reloaded.llmSettings,
            LLMSettings(
                provider: .ollama,
                endpoint: "https://example.com/v1/chat/completions",
                model: "example-model",
                ollamaModel: "qwen3:8b",
                codexModel: "gpt-5.6-terra",
                authentication: .customHeader,
                customHeaderName: "api-key",
                thinkingMode: .medium
            )
        )
        XCTAssertEqual(
            reloaded.spellingLanguageSettings,
            SpellingLanguageSettings(
                mode: .fixed,
                fixedLanguageIdentifier: "de"
            )
        )
    }
}
