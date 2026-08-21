import Foundation

public struct LLMCallDebugRequest: Identifiable, Equatable, Sendable {
    public struct Message: Equatable, Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public let id: UUID
    public let startedAt: Date
    public let endpoint: String
    public let model: String
    public let reasoningEffort: String
    public let isStreaming: Bool
    public let messages: [Message]
    public let payloadJSON: String

    public init(
        id: UUID,
        startedAt: Date,
        endpoint: String,
        model: String,
        reasoningEffort: String,
        isStreaming: Bool,
        messages: [Message],
        payloadJSON: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endpoint = endpoint
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.isStreaming = isStreaming
        self.messages = messages
        self.payloadJSON = payloadJSON
    }
}

public struct LLMTokenUsage: Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    /// The part of the output spent on thinking, for providers that break it out. It is
    /// counted inside `outputTokens`, not alongside it, so the two never add up.
    public let reasoningTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }
}

public enum LLMCallDebugEvent: Equatable, Sendable {
    case started(LLMCallDebugRequest)
    /// The moment the provider's first response byte arrived, which is what separates a
    /// slow model from a slow connection. Only sent by transports that can observe it.
    case firstByte(id: UUID, at: Date)
    /// The next piece of the model's thinking, for providers that return it.
    ///
    /// Each event carries what has arrived since the last one, never the whole, so a
    /// transport that streams reasoning can send it as it is written and one that only
    /// sees it at the end can send it in a single event.
    case reasoning(id: UUID, delta: String)
    case succeeded(
        id: UUID,
        completedAt: Date,
        statusCode: Int,
        responseBody: String,
        tokenUsage: LLMTokenUsage?
    )
    case failed(
        id: UUID,
        completedAt: Date,
        statusCode: Int?,
        error: String,
        responseBody: String?,
        tokenUsage: LLMTokenUsage?
    )
}
