import Foundation

/// How a suggestion should come across to the reader.
///
/// Deliberately short. A tone set here is a *standing* preference applied to every
/// edit, so anything wanted on one message and not the next — persuasive, empathetic,
/// confident — belongs in Rewrite…, where it is asked for by name. What is left is
/// the pair people genuinely switch between: writing to a person, and writing to work.
public enum Tone: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The default. The other cases ask for a character the author did not write,
    /// which is right only when it was actually wanted; this one asks for theirs.
    /// It also replaces the old `neutral`, which said the same thing by saying nothing.
    case keepMine
    case friendly
    case professional

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .keepMine: "Keep mine"
        default: rawValue.capitalized
        }
    }

    /// What the preference contributes to the prompt. A preset needs no gloss — the
    /// model already knows what "friendly" asks for — but a bare `keepMine` reads as
    /// no preference at all, which leaves the model free to settle into a voice of its
    /// own. So it states the instruction instead of naming a value.
    ///
    /// It says nothing about correctness. The editor prompt already ranks preferences
    /// below being correct and idiomatic, and a preference that repeats the boundary
    /// is one more thing to keep in agreement with the prompt that decides it.
    var promptDescription: String {
        switch self {
        case .keepMine:
            """
            the author's own — match the voice of their existing writing, including \
            their emoji, slang, abbreviations, and shorthand, and never trade it for \
            a smoother, warmer, or more neutral one
            """
        default:
            rawValue
        }
    }
}

/// How much a suggestion says.
///
/// Kept on its own axis. `formal` and `conversational` used to live here and merely
/// restated `professional` and `friendly` one row above, so a prompt carrying both
/// could not say which was meant to win. Length is the preference that is actually
/// independent of tone.
public enum WritingStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The default, for the same reason as `Tone.keepMine`. It also replaces the old
    /// `clear`, which asked for something the editor prompt already requires of every
    /// suggestion.
    case keepMine
    case concise
    case detailed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .keepMine: "Keep mine"
        default: rawValue.capitalized
        }
    }

    /// See `Tone.promptDescription`. `detailed` is bounded because the editor prompt
    /// asks for the smallest edit that does the job: read bare, it invites the model to
    /// pad every sentence it touches, which is the one way this preference could do harm.
    var promptDescription: String {
        switch self {
        case .keepMine:
            """
            the author's own — keep the wording, rhythm, and sentence length they \
            already use, and neither expand nor compress what they wrote
            """
        case .detailed:
            """
            detailed — spell out what the author left implicit, but never pad, and \
            never add a fact they did not give
            """
        case .concise:
            rawValue
        }
    }
}

public struct WritingProfile: Codable, Equatable, Sendable {
    public var tone: Tone
    public var style: WritingStyle
    public var promptExtension: String

    public init(
        tone: Tone = .keepMine,
        style: WritingStyle = .keepMine,
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
    case minimal
    case low
    case medium
    case high
    case extraHigh = "xhigh"
    case max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .extraHigh: "Extra high"
        case .max: "Max"
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
    /// Whether to ask the provider to send the model's thinking back with the answer.
    ///
    /// Off by default, and a choice rather than a default, because asking is not free:
    /// gateways that support it take a `reasoning` object the OpenAI API itself rejects
    /// as an unknown argument, which would fail every call for anyone pointed straight
    /// at it. It changes nothing about how hard the model thinks — only whether the
    /// thinking comes back where the call inspector can show it.
    public var includesThinking: Bool

    public init(
        provider: LLMProvider = .openAICompatible,
        endpoint: String = "",
        model: String = "",
        ollamaModel: String = "",
        codexModel: String = "",
        authentication: ProviderAuthentication = .bearer,
        customHeaderName: String = "api-key",
        thinkingMode: ThinkingMode = .off,
        includesThinking: Bool = false
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.ollamaModel = ollamaModel
        self.codexModel = codexModel
        self.authentication = authentication
        self.customHeaderName = customHeaderName
        self.thinkingMode = thinkingMode
        self.includesThinking = includesThinking
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
