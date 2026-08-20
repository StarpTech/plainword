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
            style: .concise,
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
                style: .concise,
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

    func testRetiredToneAndStyleValuesFallBackToKeepingTheAuthorsVoice() throws {
        // The presets these replaced are still sitting in the defaults of anyone who
        // picked one. Landing on `keepMine` is the right answer for them: it is the
        // one value that cannot be wrong about how they write.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("empathetic", forKey: "writingProfile.tone")
        defaults.set("persuasive", forKey: "writingProfile.style")

        let repository = SettingsRepository(suiteName: suiteName)

        XCTAssertEqual(repository.profile.tone, .keepMine)
        XCTAssertEqual(repository.profile.style, .keepMine)
    }

    func testInvalidPersistedEnumValuesFallBackWithoutDiscardingValidValues() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("unknown-tone", forKey: "writingProfile.tone")
        defaults.set(WritingStyle.concise.rawValue, forKey: "writingProfile.style")
        defaults.set("unknown-provider", forKey: "llm.provider")
        defaults.set(ProviderAuthentication.none.rawValue, forKey: "llm.authentication")
        defaults.set("unknown-thinking-mode", forKey: "llm.thinkingMode")
        defaults.set("unknown-language-mode", forKey: "spelling.languageMode")
        defaults.set("fr", forKey: "spelling.fixedLanguage")

        let repository = SettingsRepository(suiteName: suiteName)

        XCTAssertEqual(repository.profile.tone, .keepMine)
        XCTAssertEqual(repository.profile.style, .concise)
        XCTAssertEqual(repository.llmSettings.provider, .openAICompatible)
        XCTAssertEqual(repository.llmSettings.authentication, .none)
        XCTAssertEqual(repository.llmSettings.thinkingMode, .off)
        XCTAssertEqual(repository.spellingLanguageSettings.mode, .automatic)
        XCTAssertEqual(repository.spellingLanguageSettings.fixedLanguageIdentifier, "fr")
    }

    func testSavingLLMSettingsRemovesLegacyTemperaturePreferences() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "llm.sendsTemperature")
        defaults.set(0.7, forKey: "llm.temperature")

        SettingsRepository(suiteName: suiteName).llmSettings = LLMSettings()

        XCTAssertNil(defaults.object(forKey: "llm.sendsTemperature"))
        XCTAssertNil(defaults.object(forKey: "llm.temperature"))
    }
}
