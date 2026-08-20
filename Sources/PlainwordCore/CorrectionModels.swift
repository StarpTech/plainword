import Foundation

public enum Tone: String, CaseIterable, Codable, Identifiable, Sendable {
    case neutral
    case friendly
    case confident
    case empathetic
    case professional

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }
}

public enum WritingStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case clear
    case concise
    case conversational
    case formal
    case persuasive

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }
}

public struct WritingProfile: Codable, Equatable, Sendable {
    public var tone: Tone
    public var style: WritingStyle
    public var promptExtension: String

    public init(
        tone: Tone = .neutral,
        style: WritingStyle = .clear,
        promptExtension: String = ""
    ) {
        self.tone = tone
        self.style = style
        self.promptExtension = promptExtension
    }
}

public struct CorrectionResponse: Codable, Equatable, Sendable {
    public let correctedText: String
    /// Absent when the provider returned no usable classification. Consumers pass it
    /// to `WritingSuggestionPlanner`, which falls back to the shape of the diff.
    public let classification: WritingSuggestionKind?
    public let summary: String?

    public init(
        correctedText: String,
        classification: WritingSuggestionKind?,
        summary: String? = nil
    ) {
        self.correctedText = correctedText
        self.classification = classification
        self.summary = summary
    }
}

public enum ProviderAuthentication: String, CaseIterable, Codable, Identifiable, Sendable {
    case bearer
    case customHeader
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bearer: "Bearer token"
        case .customHeader: "Custom API-key header"
        case .none: "No authentication"
        }
    }
}

public enum LLMProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAICompatible
    case ollama
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI"
        case .ollama: "Ollama"
        case .codex: "Codex"
        }
    }

    public static let ollamaChatCompletionsEndpoint =
        "http://localhost:11434/v1/chat/completions"
    public static let codexAppServerEndpoint = "codex://app-server"
}

public enum ThinkingMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case off = "none"
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

public struct LLMSettings: Codable, Equatable, Sendable {
    public var provider: LLMProvider
    public var endpoint: String
    public var model: String
    public var ollamaModel: String
    public var codexModel: String
    public var authentication: ProviderAuthentication
    public var customHeaderName: String
    public var thinkingMode: ThinkingMode

    public init(
        provider: LLMProvider = .openAICompatible,
        endpoint: String = "",
        model: String = "",
        ollamaModel: String = "",
        codexModel: String = "",
        authentication: ProviderAuthentication = .bearer,
        customHeaderName: String = "api-key",
        thinkingMode: ThinkingMode = .off
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.ollamaModel = ollamaModel
        self.codexModel = codexModel
        self.authentication = authentication
        self.customHeaderName = customHeaderName
        self.thinkingMode = thinkingMode
    }

    public var resolvedEndpoint: String {
        switch provider {
        case .openAICompatible: endpoint
        case .ollama: LLMProvider.ollamaChatCompletionsEndpoint
        case .codex: LLMProvider.codexAppServerEndpoint
        }
    }

    public var resolvedModel: String {
        switch provider {
        case .openAICompatible: model
        case .ollama: ollamaModel
        case .codex: codexModel
        }
    }

    public var resolvedAuthentication: ProviderAuthentication {
        provider == .openAICompatible ? authentication : .none
    }
}
