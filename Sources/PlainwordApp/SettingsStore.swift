import AppKit
import Combine
import Foundation
import PlainwordCore

@MainActor
final class SettingsStore: ObservableObject {
    private enum PreferenceKey {
        static let appearance = "appAppearance"
        static let showsDockIcon = "showsDockIcon"
        static let popoverShortcut = "popoverShortcut"
        static let popoverShortcutConfigured = "popoverShortcutConfigured"
        static let transformShortcut = "transformShortcut"
        static let transformShortcutConfigured = "transformShortcutConfigured"
    }

    enum ConnectionState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    enum CredentialState: Equatable {
        case empty
        case saved
        case unsaved
        case failure(String)
    }

    enum OllamaModelsState: Equatable {
        case idle
        case loading
        case loaded
        case failure(String)
    }

    enum CodexState: Equatable {
        case idle
        case loading
        case ready(CodexProviderStatus)
        case failure(String)
    }

    @Published var tone: Tone {
        didSet { persistProfile() }
    }

    @Published var style: WritingStyle {
        didSet { persistProfile() }
    }

    @Published var promptExtension: String {
        didSet { persistProfile() }
    }

    @Published var spellingLanguageMode: SpellingLanguageMode {
        didSet { persistSpellingLanguageSettings() }
    }

    @Published var fixedSpellingLanguageIdentifier: String {
        didSet { persistSpellingLanguageSettings() }
    }

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: PreferenceKey.appearance)
            appearance.apply()
        }
    }

    /// Plainword lives in the menu bar, so the Dock tile is optional: hiding it
    /// also takes the app out of ⌘-Tab, which is what people asking for this want.
    @Published var showsDockIcon: Bool {
        didSet {
            defaults.set(showsDockIcon, forKey: PreferenceKey.showsDockIcon)
            applyDockIconVisibility()
        }
    }

    @Published var popoverShortcut: PopoverShortcut? {
        didSet { persistPopoverShortcut() }
    }

    @Published var transformShortcut: PopoverShortcut? {
        didSet { persistTransformShortcut() }
    }

    @Published var endpoint: String {
        didSet { persistLLMSettings() }
    }

    @Published var provider: LLMProvider {
        didSet {
            if provider == .codex, thinkingMode == .off {
                thinkingMode = .low
            }
            persistLLMSettings()
            if provider == .codex {
                Task { await loadCodexStatusIfNeeded() }
            }
        }
    }

    @Published var model: String {
        didSet { persistLLMSettings() }
    }

    @Published var ollamaModel: String {
        didSet { persistLLMSettings() }
    }

    @Published var codexModel: String {
        didSet { persistLLMSettings() }
    }

    @Published var authentication: ProviderAuthentication {
        didSet { persistLLMSettings() }
    }

    @Published var customHeaderName: String {
        didSet { persistLLMSettings() }
    }

    @Published var thinkingMode: ThinkingMode {
        didSet { persistLLMSettings() }
    }

    @Published var apiKey: String {
        didSet {
            credentialState = apiKey.isEmpty ? .empty : .unsaved
            connectionState = .idle
        }
    }

    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var credentialState: CredentialState
    @Published private(set) var ollamaModels: [String] = []
    @Published private(set) var ollamaModelsState: OllamaModelsState = .idle
    @Published private(set) var codexState: CodexState = .idle

    let llmDebugLog: LLMDebugLogStore

    private let repository: SettingsRepository
    private let defaults: UserDefaults
    private let apiKeyStore: APIKeyStore
    private let chatClient: ChatCompletionsClient
    private let ollamaClient: OllamaClient
    private let codexClient: CodexAppServerClient

    init(
        suiteName: String? = nil,
        chatClient: ChatCompletionsClient? = nil,
        ollamaClient: OllamaClient = OllamaClient(),
        codexClient: CodexAppServerClient? = nil
    ) {
        let repository = SettingsRepository(suiteName: suiteName)
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let llmDebugLog = LLMDebugLogStore()
        let storedSettings = repository.llmSettings
        let storedSpellingSettings = repository.spellingLanguageSettings
        let installedSpellingLanguages = NSSpellChecker.shared.availableLanguages
        let apiKeyStore = APIKeyStore()
        self.repository = repository
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
        self.llmDebugLog = llmDebugLog
        self.chatClient = chatClient ?? ChatCompletionsClient(
            debugHandler: { [weak llmDebugLog] event in
                await llmDebugLog?.record(event)
            }
        )
        self.ollamaClient = ollamaClient
        self.codexClient = codexClient ?? CodexAppServerClient(
            debugHandler: { [weak llmDebugLog] event in
                await llmDebugLog?.record(event)
            }
        )
        tone = repository.profile.tone
        style = repository.profile.style
        promptExtension = repository.profile.promptExtension
        spellingLanguageMode = storedSpellingSettings.mode
        fixedSpellingLanguageIdentifier = SpellingDictionaryResolver.resolve(
            languageIdentifier: storedSpellingSettings.fixedLanguageIdentifier,
            availableLanguages: installedSpellingLanguages
        ) ?? SpellingDictionaryResolver.resolve(
            languageIdentifier: Locale.current.identifier,
            availableLanguages: installedSpellingLanguages
        ) ?? installedSpellingLanguages.first ?? ""
        appearance = defaults.string(forKey: PreferenceKey.appearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .automatic
        showsDockIcon = defaults.object(forKey: PreferenceKey.showsDockIcon) as? Bool ?? true
        let storedPopoverShortcut = defaults.data(forKey: PreferenceKey.popoverShortcut)
            .flatMap { try? JSONDecoder().decode(PopoverShortcut.self, from: $0) }
        popoverShortcut = storedPopoverShortcut
            ?? (defaults.bool(forKey: PreferenceKey.popoverShortcutConfigured)
                ? nil
                : .defaultReview)
        let storedTransformShortcut = defaults.data(forKey: PreferenceKey.transformShortcut)
            .flatMap { try? JSONDecoder().decode(PopoverShortcut.self, from: $0) }
        transformShortcut = storedTransformShortcut
            ?? (defaults.bool(forKey: PreferenceKey.transformShortcutConfigured)
                ? nil
                : .defaultTransform)
        provider = storedSettings.provider
        endpoint = storedSettings.endpoint
        model = storedSettings.model
        ollamaModel = storedSettings.ollamaModel
        codexModel = storedSettings.codexModel
        authentication = storedSettings.authentication
        customHeaderName = storedSettings.customHeaderName
        let normalizedThinkingMode: ThinkingMode
        if storedSettings.provider == .codex, storedSettings.thinkingMode == .off {
            normalizedThinkingMode = .low
        } else {
            normalizedThinkingMode = storedSettings.thinkingMode
        }
        thinkingMode = normalizedThinkingMode
        do {
            let storedKey = try apiKeyStore.read() ?? ""
            apiKey = storedKey
            credentialState = storedKey.isEmpty ? .empty : .saved
        } catch {
            apiKey = ""
            credentialState = .failure(error.localizedDescription)
        }
        if normalizedThinkingMode != storedSettings.thinkingMode {
            persistLLMSettings()
        }
        if provider == .codex {
            Task { [weak self] in
                await self?.loadCodexStatusIfNeeded()
            }
        }
    }

    /// Applies the stored choice to the running app. Switching policy drops the
    /// app's active state, so whichever window was frontmost is raised again.
    func applyDockIconVisibility() {
        guard let application = NSApp else { return }
        let policy: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        guard application.activationPolicy() != policy else { return }

        let frontmostWindow = application.keyWindow ?? application.mainWindow
        application.setActivationPolicy(policy)
        if frontmostWindow != nil || policy == .regular {
            application.activate(ignoringOtherApps: true)
            frontmostWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func persistPopoverShortcut() {
        defaults.set(true, forKey: PreferenceKey.popoverShortcutConfigured)
        guard let popoverShortcut,
              let data = try? JSONEncoder().encode(popoverShortcut) else {
            defaults.removeObject(forKey: PreferenceKey.popoverShortcut)
            return
        }
        defaults.set(data, forKey: PreferenceKey.popoverShortcut)
    }

    private func persistTransformShortcut() {
        defaults.set(true, forKey: PreferenceKey.transformShortcutConfigured)
        guard let transformShortcut,
              let data = try? JSONEncoder().encode(transformShortcut) else {
            defaults.removeObject(forKey: PreferenceKey.transformShortcut)
            return
        }
        defaults.set(data, forKey: PreferenceKey.transformShortcut)
    }

    var llmSettings: LLMSettings {
        LLMSettings(
            provider: provider,
            endpoint: endpoint,
            model: model,
            ollamaModel: ollamaModel,
            codexModel: codexModel,
            authentication: authentication,
            customHeaderName: customHeaderName,
            thinkingMode: thinkingMode
        )
    }

    var spellingLanguageSettings: SpellingLanguageSettings {
        SpellingLanguageSettings(
            mode: spellingLanguageMode,
            fixedLanguageIdentifier: fixedSpellingLanguageIdentifier
        )
    }

    var availableSpellingLanguages: [String] {
        NSSpellChecker.shared.availableLanguages.sorted {
            spellingLanguageDisplayName($0).localizedStandardCompare(
                spellingLanguageDisplayName($1)
            ) == .orderedAscending
        }
    }

    func spellingLanguageDisplayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier)
            ?? Locale.current.localizedString(forLanguageCode: identifier)
            ?? identifier
    }

    var endpointURL: URL? {
        let trimmed = llmSettings.resolvedEndpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              url.host != nil else {
            return nil
        }
        let local = url.host == "localhost" || url.host == "127.0.0.1"
        return scheme == "https" || (scheme == "http" && local) ? url : nil
    }

    var isLLMConfigured: Bool {
        switch provider {
        case .codex:
            if case .failure = codexState { return false }
            return true
        case .openAICompatible, .ollama:
            return endpointURL != nil
                && !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (!requiresCredential || credentialState == .saved)
        }
    }

    var selectedModel: String {
        switch provider {
        case .openAICompatible: model
        case .ollama: ollamaModel
        case .codex: codexModel
        }
    }

    var requiresCredential: Bool {
        llmSettings.resolvedAuthentication != .none
    }

    var ollamaModelOptions: [String] {
        let selected = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !ollamaModels.contains(selected) else {
            return ollamaModels
        }
        return [selected] + ollamaModels
    }

    var codexModelOptions: [CodexModel] {
        let selected = codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .ready(let status) = codexState else {
            guard !selected.isEmpty else { return [] }
            return [CodexModel(id: selected, displayName: selected, isDefault: false)]
        }
        let models = status.models.filter(\.isLatencyOptimized)
            + status.models.filter { !$0.isLatencyOptimized }
        guard !selected.isEmpty, !models.contains(where: { $0.id == selected }) else {
            return models
        }
        return [CodexModel(id: selected, displayName: selected, isDefault: false)]
            + models
    }

    func saveAPIKey() {
        do {
            try apiKeyStore.save(apiKey)
            credentialState = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .empty
                : .saved
        } catch {
            credentialState = .failure(error.localizedDescription)
        }
    }

    func clearAPIKey() {
        do {
            try apiKeyStore.delete()
            apiKey = ""
            credentialState = .empty
        } catch {
            credentialState = .failure(error.localizedDescription)
        }
    }

    func testConnection() async {
        connectionState = .testing
        do {
            let response: CorrectionResponse
            if provider == .codex {
                let status = try await codexClient.status()
                codexState = .ready(status)
                response = try await codexClient.correct(
                    text: "This is an connection test.",
                    profile: writingProfile,
                    locale: Locale.current.identifier,
                    settings: llmSettings
                )
            } else {
                response = try await chatClient.correct(
                    text: "This is an connection test.",
                    profile: writingProfile,
                    locale: Locale.current.identifier,
                    settings: llmSettings,
                    apiKey: apiKeyForRequest
                )
            }
            connectionState = .success(response.correctedText)
        } catch {
            connectionState = .failure(error.localizedDescription)
        }
    }

    func loadOllamaModelsIfNeeded() async {
        guard provider == .ollama, ollamaModelsState == .idle else { return }
        await refreshOllamaModels()
    }

    func refreshOllamaModels() async {
        ollamaModelsState = .loading
        do {
            let models = try await ollamaClient.models()
            try Task.checkCancellation()
            ollamaModels = models
            if ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let firstModel = models.first {
                ollamaModel = firstModel
            }
            ollamaModelsState = .loaded
        } catch is CancellationError {
            ollamaModelsState = .idle
        } catch {
            ollamaModelsState = .failure(error.localizedDescription)
        }
    }

    func loadCodexStatusIfNeeded() async {
        guard provider == .codex, codexState == .idle else { return }
        await refreshCodexStatus()
    }

    func refreshCodexStatus() async {
        codexState = .loading
        do {
            let status = try await codexClient.status()
            try Task.checkCancellation()
            codexState = .ready(status)
        } catch is CancellationError {
            codexState = .idle
        } catch {
            codexState = .failure(error.localizedDescription)
        }
    }

    func shutdown() async {
        await codexClient.shutdown()
    }

    func correct(_ text: String) async throws -> CorrectionResponse {
        guard isLLMConfigured else {
            throw DesktopCorrectionError.providerNotConfigured
        }

        if provider == .codex {
            return try await codexClient.correct(
                text: text,
                profile: writingProfile,
                locale: Locale.current.identifier,
                settings: llmSettings
            )
        } else {
            return try await chatClient.correct(
                text: text,
                profile: writingProfile,
                locale: Locale.current.identifier,
                settings: llmSettings,
                apiKey: apiKeyForRequest
            )
        }
    }

    func streamCorrection(
        _ text: String
    ) throws -> AsyncThrowingStream<CorrectionStreamEvent, Error> {
        guard isLLMConfigured else {
            throw DesktopCorrectionError.providerNotConfigured
        }

        if provider == .codex {
            return codexClient.streamCorrection(
                text: text,
                profile: writingProfile,
                locale: Locale.current.identifier,
                settings: llmSettings
            )
        } else {
            return chatClient.streamCorrection(
                text: text,
                profile: writingProfile,
                locale: Locale.current.identifier,
                settings: llmSettings,
                apiKey: apiKeyForRequest
            )
        }
    }

    func streamCorrection(
        _ context: TextEditContext,
        intent: EditIntent,
        locale: String,
        instruction: String? = nil
    ) throws -> AsyncThrowingStream<CorrectionStreamEvent, Error> {
        guard isLLMConfigured else {
            throw DesktopCorrectionError.providerNotConfigured
        }

        if provider == .codex {
            return codexClient.streamCorrection(
                text: context.text,
                applicationContext: context.applicationContext,
                applicationContextFragments: context.applicationContextFragments,
                leadingContext: context.leadingContext,
                trailingContext: context.trailingContext,
                instruction: instruction,
                intent: intent,
                profile: writingProfile,
                locale: locale,
                settings: llmSettings
            )
        } else {
            return chatClient.streamCorrection(
                text: context.text,
                applicationContext: context.applicationContext,
                applicationContextFragments: context.applicationContextFragments,
                leadingContext: context.leadingContext,
                trailingContext: context.trailingContext,
                instruction: instruction,
                intent: intent,
                profile: writingProfile,
                locale: locale,
                settings: llmSettings,
                apiKey: apiKeyForRequest
            )
        }
    }

    private var apiKeyForRequest: String? {
        requiresCredential ? apiKey : nil
    }

    private var writingProfile: WritingProfile {
        WritingProfile(
            tone: tone,
            style: style,
            promptExtension: promptExtension
        )
    }

    private func persistProfile() {
        repository.profile = writingProfile
    }

    private func persistSpellingLanguageSettings() {
        repository.spellingLanguageSettings = spellingLanguageSettings
    }

    private func persistLLMSettings() {
        repository.llmSettings = llmSettings
        connectionState = .idle
    }
}

enum DesktopCorrectionError: LocalizedError {
    case providerNotConfigured

    var errorDescription: String? {
        switch self {
        case .providerNotConfigured:
            "Configure and save your LLM provider first."
        }
    }
}
