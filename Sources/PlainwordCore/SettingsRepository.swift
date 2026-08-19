import Foundation

public struct SettingsRepository: Sendable {
    private enum Key {
        static let tone = "writingProfile.tone"
        static let style = "writingProfile.style"
        static let promptExtension = "writingProfile.promptExtension"
        static let provider = "llm.provider"
        static let endpoint = "llm.endpoint"
        static let model = "llm.model"
        static let ollamaModel = "llm.ollamaModel"
        static let codexModel = "llm.codexModel"
        static let authentication = "llm.authentication"
        static let customHeaderName = "llm.customHeaderName"
        static let thinkingMode = "llm.thinkingMode"
        static let spellingLanguageMode = "spelling.languageMode"
        static let fixedSpellingLanguage = "spelling.fixedLanguage"
    }

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    public var profile: WritingProfile {
        get {
            let defaults = makeDefaults()
            let tone = defaults.string(forKey: Key.tone).flatMap(Tone.init(rawValue:)) ?? .neutral
            let style = defaults.string(forKey: Key.style).flatMap(WritingStyle.init(rawValue:)) ?? .clear
            return WritingProfile(
                tone: tone,
                style: style,
                promptExtension: defaults.string(forKey: Key.promptExtension) ?? ""
            )
        }
        nonmutating set {
            let defaults = makeDefaults()
            defaults.set(newValue.tone.rawValue, forKey: Key.tone)
            defaults.set(newValue.style.rawValue, forKey: Key.style)
            defaults.set(newValue.promptExtension, forKey: Key.promptExtension)
        }
    }

    public var llmSettings: LLMSettings {
        get {
            let defaults = makeDefaults()
            let authentication = defaults.string(forKey: Key.authentication)
                .flatMap(ProviderAuthentication.init(rawValue:)) ?? .bearer
            return LLMSettings(
                provider: defaults.string(forKey: Key.provider)
                    .flatMap(LLMProvider.init(rawValue:)) ?? .openAICompatible,
                endpoint: defaults.string(forKey: Key.endpoint) ?? "",
                model: defaults.string(forKey: Key.model) ?? "",
                ollamaModel: defaults.string(forKey: Key.ollamaModel) ?? "",
                codexModel: defaults.string(forKey: Key.codexModel) ?? "",
                authentication: authentication,
                customHeaderName: defaults.string(forKey: Key.customHeaderName) ?? "api-key",
                thinkingMode: defaults.string(forKey: Key.thinkingMode)
                    .flatMap(ThinkingMode.init(rawValue:)) ?? .low
            )
        }
        nonmutating set {
            let defaults = makeDefaults()
            defaults.set(newValue.provider.rawValue, forKey: Key.provider)
            defaults.set(newValue.endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.endpoint)
            defaults.set(newValue.model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.model)
            defaults.set(newValue.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.ollamaModel)
            defaults.set(newValue.codexModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.codexModel)
            defaults.set(newValue.authentication.rawValue, forKey: Key.authentication)
            defaults.set(newValue.customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.customHeaderName)
            defaults.set(newValue.thinkingMode.rawValue, forKey: Key.thinkingMode)
            defaults.removeObject(forKey: "llm.sendsTemperature")
            defaults.removeObject(forKey: "llm.temperature")
        }
    }

    public var spellingLanguageSettings: SpellingLanguageSettings {
        get {
            let defaults = makeDefaults()
            return SpellingLanguageSettings(
                mode: defaults.string(forKey: Key.spellingLanguageMode)
                    .flatMap(SpellingLanguageMode.init(rawValue:)) ?? .automatic,
                fixedLanguageIdentifier: defaults.string(
                    forKey: Key.fixedSpellingLanguage
                ) ?? ""
            )
        }
        nonmutating set {
            let defaults = makeDefaults()
            defaults.set(newValue.mode.rawValue, forKey: Key.spellingLanguageMode)
            defaults.set(
                newValue.fixedLanguageIdentifier,
                forKey: Key.fixedSpellingLanguage
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
