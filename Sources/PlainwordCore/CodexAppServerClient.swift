import Foundation

public enum CodexAppServerClientError: Error, LocalizedError, Equatable, Sendable {
    case cliNotFound
    case cliNotExecutable(String)
    case failedToLaunch(String)
    case processExited(status: Int32, details: String?)
    case requestTimedOut
    case invalidResponse
    case notSignedIn
    case subscriptionLoginRequired
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Codex CLI was not found. Install it, or set PLAINWORD_CODEX_PATH to its executable."
        case .cliNotExecutable(let path):
            "Codex CLI is not executable at \(path)."
        case .failedToLaunch(let message):
            "Codex CLI could not start: \(message)"
        case let .processExited(status, details):
            if let details, !details.isEmpty {
                "Codex CLI stopped unexpectedly (status \(status)): \(details)"
            } else {
                "Codex CLI stopped unexpectedly (status \(status))."
            }
        case .requestTimedOut:
            "Codex CLI did not respond in time."
        case .invalidResponse:
            "Codex CLI returned an unreadable response."
        case .notSignedIn:
            "Codex CLI is not signed in. Run `codex login` in Terminal, then try again."
        case .subscriptionLoginRequired:
            "Codex CLI is not using a ChatGPT subscription. Run `codex logout`, then `codex login` and choose ChatGPT."
        case .server(let message):
            message
        }
    }
}

public struct CodexModel: Identifiable, Equatable, Sendable {
    public static let latencyOptimizedModelID = "gpt-5.3-codex-spark"

    public let id: String
    public let displayName: String
    public let isDefault: Bool

    public init(id: String, displayName: String, isDefault: Bool) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
    }

    public var isLatencyOptimized: Bool {
        id == Self.latencyOptimizedModelID
    }
}

public struct CodexProviderStatus: Equatable, Sendable {
    public let executablePath: String
    public let email: String?
    public let planType: String
    public let models: [CodexModel]

    public init(
        executablePath: String,
        email: String?,
        planType: String,
        models: [CodexModel]
    ) {
        self.executablePath = executablePath
        self.email = email
        self.planType = planType
        self.models = models
    }

    public var planDisplayName: String {
        switch planType {
        case "free": "Free"
        case "go": "Go"
        case "plus": "Plus"
        case "pro": "Pro"
        case "prolite": "Pro"
        case "team": "Team"
        case "self_serve_business_usage_based", "business": "Business"
        case "ent26", "enterprise_cbp_usage_based", "enterprise": "Enterprise"
        case "edu": "Edu"
        default: "ChatGPT"
        }
    }
}

enum CodexJSONValue: Codable, Equatable, Sendable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: CodexJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> CodexJSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        switch self {
        case .integer(let value): value
        case .double(let value): Int(exactly: value)
        default: nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [CodexJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: CodexJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

private struct CodexIncomingMessage: Decodable {
    struct RPCError: Decodable {
        let code: Int
        let message: String
    }

    let id: Int?
    let method: String?
    let params: CodexJSONValue?
    let result: CodexJSONValue?
    let error: RPCError?
}

private final class RunningCodexProcess: @unchecked Sendable {
    let id: UUID
    let process: Process
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    init(
        id: UUID,
        process: Process,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) {
        self.id = id
        self.process = process
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    deinit {
        standardOutput.readabilityHandler = nil
        standardError.readabilityHandler = nil
        try? standardInput.close()
        try? standardOutput.close()
        try? standardError.close()
        if process.isRunning {
            process.terminate()
        }
    }
}

public actor CodexAppServerClient {
    // Plainword only needs structured text generation. Turning off Codex's
    // agent capabilities keeps their tool schemas and instructions out of
    // every ephemeral editing thread.
    private static let disabledAgentFeatures = [
        "apps",
        "browser_use",
        "computer_use",
        "goals",
        "hooks",
        "image_generation",
        "in_app_browser",
        "mentions_v2",
        "multi_agent",
        "plugins",
        "shell_tool",
        "skill_search",
        "tool_suggest",
        "unified_exec",
        "view_image",
        "workspace_dependencies"
    ]

    private struct PendingRequest {
        let continuation: CheckedContinuation<CodexJSONValue, Error>
    }

    private struct TurnResult: Sendable {
        let text: String
        let usage: LLMTokenUsage?
    }

    private struct ActiveTurn {
        var turnID: String?
        var streamedText = ""
        var finalText: String?
        var usage: LLMTokenUsage?
        var errorMessage: String?
        let continuation: CheckedContinuation<TurnResult, Error>
    }

    private let configuredExecutableURL: URL?
    private let requestTimeout: TimeInterval
    private let turnTimeout: TimeInterval
    private let debugHandler: (@Sendable (LLMCallDebugEvent) async -> Void)?

    private var executableURL: URL?
    private var runningProcess: RunningCodexProcess?
    private var isInitialized = false
    private var isShutDown = false
    private var startupTask: Task<Void, Error>?
    private var standardOutputBuffer = Data()
    private var standardErrorBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var activeTurns: [String: ActiveTurn] = [:]
    private var cancelledThreadIDs: Set<String> = []
    private var configuredMCPServerNames: [String] = []

    public init(
        executableURL: URL? = nil,
        requestTimeout: TimeInterval = 20,
        turnTimeout: TimeInterval = 60,
        debugHandler: (@Sendable (LLMCallDebugEvent) async -> Void)? = nil
    ) {
        configuredExecutableURL = executableURL
        self.requestTimeout = requestTimeout
        self.turnTimeout = turnTimeout
        self.debugHandler = debugHandler
    }

    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        startupTask?.cancel()
        failAll(with: CancellationError())
        stopProcess()
    }

    public func status() async throws -> CodexProviderStatus {
        try await ensureStarted()
        let accountResult = try await request(
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )
        guard let account = accountResult["account"] else {
            throw CodexAppServerClientError.invalidResponse
        }
        guard case .object = account else {
            if account == .null {
                throw CodexAppServerClientError.notSignedIn
            }
            throw CodexAppServerClientError.invalidResponse
        }
        guard account["type"]?.stringValue == "chatgpt" else {
            throw CodexAppServerClientError.subscriptionLoginRequired
        }
        guard let planType = account["planType"]?.stringValue else {
            throw CodexAppServerClientError.invalidResponse
        }

        var models: [CodexModel] = []
        var cursor: String?
        repeat {
            var parameters: [String: CodexJSONValue] = [
                "limit": .integer(100),
                "includeHidden": .bool(false)
            ]
            if let cursor {
                parameters["cursor"] = .string(cursor)
            }
            let result = try await request(
                method: "model/list",
                params: .object(parameters)
            )
            guard let page = result["data"]?.arrayValue else {
                throw CodexAppServerClientError.invalidResponse
            }
            models += page.compactMap(Self.decodeModel)
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil

        guard let executableURL else {
            throw CodexAppServerClientError.invalidResponse
        }
        return CodexProviderStatus(
            executablePath: executableURL.path,
            email: account["email"]?.stringValue,
            planType: planType,
            models: models
        )
    }

    public func correct(
        text: String,
        applicationContext: String = "",
        applicationContextFragments: [ReadOnlyContextFragment] = [],
        leadingContext: String = "",
        trailingContext: String = "",
        instruction: String? = nil,
        intent: EditIntent = .correctOrComplete,
        profile: WritingProfile,
        locale: String,
        settings: LLMSettings
    ) async throws -> CorrectionResponse {
        let messages = ChatCompletionsClient.messages(
            text: text,
            applicationContext: applicationContext,
            applicationContextFragments: applicationContextFragments,
            leadingContext: leadingContext,
            trailingContext: trailingContext,
            instruction: instruction,
            intent: intent,
            profile: profile,
            locale: locale
        )
        guard messages.count == 2 else {
            throw CodexAppServerClientError.invalidResponse
        }

        let model = settings.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadParameters = Self.threadParameters(
            systemPrompt: messages[0].content,
            model: model
        )
        let turnParameters = Self.turnParameters(
            threadID: "<created-by-codex>",
            userPrompt: messages[1].content,
            intent: intent,
            thinkingMode: settings.thinkingMode
        )
        let debugRequest = LLMCallDebugRequest(
            id: UUID(),
            startedAt: Date(),
            endpoint: "codex app-server (local stdio)",
            model: model.isEmpty ? "Codex default" : model,
            reasoningEffort: Self.reasoningEffort(for: settings.thinkingMode),
            isStreaming: true,
            messages: messages.map { .init(role: $0.role, content: $0.content) },
            payloadJSON: Self.prettyJSON(.object([
                "thread/start": threadParameters,
                "turn/start": turnParameters
            ]))
        )
        await debugHandler?(.started(debugRequest))

        do {
            var attempt = 0
            while true {
                do {
                    let result = try await performTurn(
                        systemPrompt: messages[0].content,
                        userPrompt: messages[1].content,
                        model: model,
                        thinkingMode: settings.thinkingMode,
                        intent: intent
                    )
                    let correction = try ChatCompletionsClient.decodeStructuredCorrection(
                        result.text,
                        original: text,
                        summary: "\(profile.tone.displayName) · \(profile.style.displayName)",
                        allowsExpansion: instruction != nil
                    )
                    await debugHandler?(
                        .succeeded(
                            id: debugRequest.id,
                            completedAt: Date(),
                            statusCode: 200,
                            responseBody: result.text,
                            tokenUsage: result.usage
                        )
                    )
                    return correction
                } catch {
                    guard attempt == 0, Self.shouldResetProcess(after: error) else {
                        throw error
                    }
                    attempt += 1
                    stopProcess()
                }
            }
        } catch {
            await debugHandler?(
                .failed(
                    id: debugRequest.id,
                    completedAt: Date(),
                    statusCode: nil,
                    error: error.localizedDescription,
                    responseBody: nil,
                    tokenUsage: nil
                )
            )
            throw error
        }
    }

    public nonisolated func streamCorrection(
        text: String,
        applicationContext: String = "",
        applicationContextFragments: [ReadOnlyContextFragment] = [],
        leadingContext: String = "",
        trailingContext: String = "",
        instruction: String? = nil,
        intent: EditIntent = .correctOrComplete,
        profile: WritingProfile,
        locale: String,
        settings: LLMSettings
    ) -> AsyncThrowingStream<CorrectionResponse, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let correction = try await self.correct(
                        text: text,
                        applicationContext: applicationContext,
                        applicationContextFragments: applicationContextFragments,
                        leadingContext: leadingContext,
                        trailingContext: trailingContext,
                        instruction: instruction,
                        intent: intent,
                        profile: profile,
                        locale: locale,
                        settings: settings
                    )
                    continuation.yield(correction)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    static func threadParameters(
        systemPrompt: String,
        model: String,
        disabledMCPServerNames: [String] = []
    ) -> CodexJSONValue {
        var config: [String: CodexJSONValue] = [
            "features": .object(
                Dictionary(
                    uniqueKeysWithValues: disabledAgentFeatures.map { ($0, .bool(false)) }
                )
            ),
            "include_apps_instructions": .bool(false),
            "include_collaboration_mode_instructions": .bool(false),
            "include_environment_context": .bool(false),
            "include_permissions_instructions": .bool(false),
            "personality": .string("none"),
            "skills": .object([
                "include_instructions": .bool(false),
                "bundled": .object(["enabled": .bool(false)])
            ]),
            "web_search": .string("disabled")
        ]
        if !disabledMCPServerNames.isEmpty {
            config["mcp_servers"] = .object(
                Dictionary(
                    uniqueKeysWithValues: disabledMCPServerNames.map {
                        ($0, .object(["enabled": .bool(false)]))
                    }
                )
            )
        }
        var values: [String: CodexJSONValue] = [
            "serviceName": .string("plainword"),
            "baseInstructions": .string(systemPrompt),
            "developerInstructions": .string(""),
            "personality": .string("none"),
            "cwd": .string(FileManager.default.temporaryDirectory.path),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "ephemeral": .bool(true),
            "config": .object(config)
        ]
        if !model.isEmpty {
            values["model"] = .string(model)
        }
        return .object(values)
    }

    static func turnParameters(
        threadID: String,
        userPrompt: String,
        intent: EditIntent,
        thinkingMode: ThinkingMode
    ) -> CodexJSONValue {
        let classifications = intent == .correct
            ? [WritingSuggestionKind.correction.rawValue, WritingSuggestionKind.rewrite.rawValue]
            : [
                WritingSuggestionKind.correction.rawValue,
                WritingSuggestionKind.rewrite.rawValue,
                WritingSuggestionKind.completion.rawValue
            ]
        var values: [String: CodexJSONValue] = [
            "threadId": .string(threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(userPrompt)
                ])
            ]),
            "outputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "corrected_text": .object(["type": .string("string")]),
                    "classification": .object([
                        "type": .string("string"),
                        "enum": .array(classifications.map(CodexJSONValue.string))
                    ])
                ]),
                "required": .array([
                    .string("corrected_text"),
                    .string("classification")
                ]),
                "additionalProperties": .bool(false)
            ])
        ]
        values["effort"] = .string(reasoningEffort(for: thinkingMode))
        return .object(values)
    }

    static func reasoningEffort(for thinkingMode: ThinkingMode) -> String {
        // Codex models do not advertise a no-reasoning effort. Omitting the
        // value would inherit the CLI configuration, which may be much higher.
        thinkingMode == .off ? ThinkingMode.low.rawValue : thinkingMode.rawValue
    }

    private func performTurn(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        thinkingMode: ThinkingMode,
        intent: EditIntent
    ) async throws -> TurnResult {
        try await ensureStarted()
        let threadResult = try await request(
            method: "thread/start",
            params: Self.threadParameters(
                systemPrompt: systemPrompt,
                model: model,
                disabledMCPServerNames: configuredMCPServerNames
            )
        )
        guard let threadID = threadResult["thread"]?["id"]?.stringValue else {
            throw CodexAppServerClientError.invalidResponse
        }
        let parameters = Self.turnParameters(
            threadID: threadID,
            userPrompt: userPrompt,
            intent: intent,
            thinkingMode: thinkingMode
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                activeTurns[threadID] = ActiveTurn(continuation: continuation)
                Task { [weak self] in
                    await self?.startTurn(threadID: threadID, parameters: parameters)
                }
                let nanoseconds = UInt64(max(turnTimeout, 1) * 1_000_000_000)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    await self?.timeOutTurn(threadID: threadID)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelTurn(threadID: threadID)
            }
        }
    }

    private func startTurn(threadID: String, parameters: CodexJSONValue) async {
        do {
            let result = try await request(method: "turn/start", params: parameters)
            guard let turnID = result["turn"]?["id"]?.stringValue else {
                throw CodexAppServerClientError.invalidResponse
            }
            if var activeTurn = activeTurns[threadID] {
                activeTurn.turnID = turnID
                activeTurns[threadID] = activeTurn
            } else if cancelledThreadIDs.remove(threadID) != nil {
                await interrupt(turnID: turnID, threadID: threadID)
            }
        } catch {
            failTurn(threadID: threadID, error: error)
        }
    }

    private func cancelTurn(threadID: String) async {
        guard let turn = activeTurns.removeValue(forKey: threadID) else { return }
        cancelledThreadIDs.insert(threadID)
        turn.continuation.resume(throwing: CancellationError())
        if let turnID = turn.turnID {
            cancelledThreadIDs.remove(threadID)
            await interrupt(turnID: turnID, threadID: threadID)
        }
        await unsubscribe(threadID: threadID)
    }

    private func interrupt(turnID: String, threadID: String) async {
        _ = try? await request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ])
        )
    }

    private func unsubscribe(threadID: String) async {
        guard runningProcess != nil else { return }
        _ = try? await sendRequest(
            method: "thread/unsubscribe",
            params: .object(["threadId": .string(threadID)])
        )
    }

    private func ensureStarted() async throws {
        guard !isShutDown else { throw CancellationError() }
        if let startupTask {
            return try await startupTask.value
        }
        if isInitialized, runningProcess?.process.isRunning == true {
            return
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.startAndInitialize()
        }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func startAndInitialize() async throws {
        let resolvedURL = try Self.resolveExecutable(configuredExecutableURL)
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let processID = UUID()

        process.executableURL = resolvedURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { [weak self] in
                await self?.receiveStandardOutput(data, processID: processID)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { [weak self] in
                await self?.receiveStandardError(data, processID: processID)
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { [weak self] in
                await self?.processDidExit(processID: processID, status: status)
            }
        }

        runningProcess = RunningCodexProcess(
            id: processID,
            process: process,
            standardInput: inputPipe.fileHandleForWriting,
            standardOutput: outputPipe.fileHandleForReading,
            standardError: errorPipe.fileHandleForReading
        )
        standardOutputBuffer.removeAll(keepingCapacity: true)
        standardErrorBuffer.removeAll(keepingCapacity: true)
        executableURL = resolvedURL

        do {
            try process.run()
        } catch {
            stopProcess()
            throw CodexAppServerClientError.failedToLaunch(error.localizedDescription)
        }

        do {
            _ = try await sendRequest(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("plainword"),
                        "title": .string("Plainword"),
                        "version": .string("1.0.0")
                    ])
                ])
            )
            try sendNotification(method: "initialized", params: .object([:]))
            isInitialized = true
            await discoverConfiguredMCPServers()
        } catch {
            stopProcess()
            throw error
        }
    }

    private func discoverConfiguredMCPServers() async {
        let result = try? await sendRequest(
            method: "config/read",
            params: .object([
                "cwd": .string(FileManager.default.temporaryDirectory.path),
                "includeLayers": .bool(false)
            ])
        )
        configuredMCPServerNames = result?["config"]?["mcp_servers"]?
            .objectValue?
            .keys
            .sorted() ?? []
    }

    private func request(
        method: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue {
        try await ensureStarted()
        return try await sendRequest(method: method, params: params)
    }

    private func sendRequest(
        method: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue {
        try Task.checkCancellation()
        guard !isShutDown else { throw CancellationError() }
        guard runningProcess?.process.isRunning == true else {
            throw CodexAppServerClientError.processExited(
                status: runningProcess?.process.terminationStatus ?? -1,
                details: standardErrorDescription
            )
        }
        let requestID = nextRequestID
        nextRequestID += 1
        let message = CodexJSONValue.object([
            "method": .string(method),
            "id": .integer(requestID),
            "params": params
        ])
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            data = try encoder.encode(message) + Data([0x0A])
        } catch {
            throw CodexAppServerClientError.invalidResponse
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[requestID] = PendingRequest(continuation: continuation)
                do {
                    try runningProcess?.standardInput.write(contentsOf: data)
                } catch {
                    pendingRequests.removeValue(forKey: requestID)
                    continuation.resume(
                        throwing: CodexAppServerClientError.processExited(
                            status: runningProcess?.process.terminationStatus ?? -1,
                            details: error.localizedDescription
                        )
                    )
                    return
                }
                let nanoseconds = UInt64(max(requestTimeout, 0.1) * 1_000_000_000)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    await self?.timeOutRequest(requestID)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(requestID)
            }
        }
    }

    private func sendNotification(method: String, params: CodexJSONValue) throws {
        guard !isShutDown else { throw CancellationError() }
        guard let runningProcess, runningProcess.process.isRunning else {
            throw CodexAppServerClientError.processExited(
                status: runningProcess?.process.terminationStatus ?? -1,
                details: standardErrorDescription
            )
        }
        let message = CodexJSONValue.object([
            "method": .string(method),
            "params": params
        ])
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let data = try encoder.encode(message) + Data([0x0A])
            try runningProcess.standardInput.write(contentsOf: data)
        } catch {
            throw CodexAppServerClientError.processExited(
                status: runningProcess.process.terminationStatus,
                details: error.localizedDescription
            )
        }
    }

    private func receiveStandardOutput(_ data: Data, processID: UUID) {
        guard runningProcess?.id == processID else { return }
        standardOutputBuffer.append(data)
        while let newlineIndex = standardOutputBuffer.firstIndex(of: 0x0A) {
            let line = Data(standardOutputBuffer[..<newlineIndex])
            standardOutputBuffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else { continue }
            handleLine(line)
        }
        if standardOutputBuffer.count > 8_388_608 {
            processDidFailProtocol()
        }
    }

    private func receiveStandardError(_ data: Data, processID: UUID) {
        guard runningProcess?.id == processID else { return }
        standardErrorBuffer.append(data)
        if standardErrorBuffer.count > 16_384 {
            standardErrorBuffer = Data(standardErrorBuffer.suffix(16_384))
        }
    }

    private func handleLine(_ data: Data) {
        guard let message = try? JSONDecoder().decode(CodexIncomingMessage.self, from: data)
        else {
            processDidFailProtocol()
            return
        }
        if let requestID = message.id, message.method == nil {
            guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
            if let error = message.error {
                pending.continuation.resume(
                    throwing: CodexAppServerClientError.server(
                        String(error.message.prefix(500))
                    )
                )
            } else {
                pending.continuation.resume(returning: message.result ?? .null)
            }
            return
        }
        guard let method = message.method, let params = message.params else { return }
        handleNotification(method: method, params: params)
    }

    private func handleNotification(method: String, params: CodexJSONValue) {
        guard let threadID = params["threadId"]?.stringValue else { return }
        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"]?.stringValue,
                  var turn = activeTurns[threadID] else { return }
            turn.streamedText += delta
            activeTurns[threadID] = turn

        case "item/completed":
            guard let item = params["item"],
                  item["type"]?.stringValue == "agentMessage",
                  let text = item["text"]?.stringValue,
                  var turn = activeTurns[threadID] else { return }
            let phase = item["phase"]?.stringValue
            if phase == nil || phase == "final_answer" {
                turn.finalText = text
                activeTurns[threadID] = turn
            }

        case "thread/tokenUsage/updated":
            guard let breakdown = params["tokenUsage"]?["last"],
                  var turn = activeTurns[threadID] else { return }
            turn.usage = LLMTokenUsage(
                inputTokens: breakdown["inputTokens"]?.integerValue,
                outputTokens: breakdown["outputTokens"]?.integerValue,
                totalTokens: breakdown["totalTokens"]?.integerValue,
                cacheReadTokens: breakdown["cachedInputTokens"]?.integerValue,
                cacheWriteTokens: breakdown["cacheWriteInputTokens"]?.integerValue
            )
            activeTurns[threadID] = turn

        case "error":
            guard var turn = activeTurns[threadID] else { return }
            turn.errorMessage = params["error"]?["message"]?.stringValue
            activeTurns[threadID] = turn

        case "turn/completed":
            guard let turnValue = params["turn"],
                  let status = turnValue["status"]?.stringValue,
                  let activeTurn = activeTurns.removeValue(forKey: threadID) else { return }
            if status == "completed" {
                let text = activeTurn.finalText ?? activeTurn.streamedText
                guard !text.isEmpty else {
                    activeTurn.continuation.resume(
                        throwing: CodexAppServerClientError.invalidResponse
                    )
                    Task { [weak self] in await self?.unsubscribe(threadID: threadID) }
                    return
                }
                activeTurn.continuation.resume(
                    returning: TurnResult(text: text, usage: activeTurn.usage)
                )
            } else if status == "interrupted" {
                activeTurn.continuation.resume(throwing: CancellationError())
            } else {
                let message = turnValue["error"]?["message"]?.stringValue
                    ?? activeTurn.errorMessage
                    ?? "Codex could not complete the request."
                activeTurn.continuation.resume(
                    throwing: CodexAppServerClientError.server(String(message.prefix(500)))
                )
            }
            Task { [weak self] in await self?.unsubscribe(threadID: threadID) }

        default:
            break
        }
    }

    private func processDidExit(processID: UUID, status: Int32) {
        guard runningProcess?.id == processID else { return }
        let error = CodexAppServerClientError.processExited(
            status: status,
            details: standardErrorDescription
        )
        runningProcess = nil
        isInitialized = false
        configuredMCPServerNames = []
        failAll(with: error)
    }

    private func processDidFailProtocol() {
        let error = CodexAppServerClientError.invalidResponse
        stopProcess()
        failAll(with: error)
    }

    private func failAll(with error: Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.continuation.resume(throwing: error)
        }
        let turns = activeTurns.values
        activeTurns.removeAll()
        for turn in turns {
            turn.continuation.resume(throwing: error)
        }
        cancelledThreadIDs.removeAll()
    }

    private func failTurn(threadID: String, error: Error) {
        guard let turn = activeTurns.removeValue(forKey: threadID) else { return }
        turn.continuation.resume(throwing: error)
        Task { [weak self] in await self?.unsubscribe(threadID: threadID) }
    }

    private func timeOutRequest(_ requestID: Int) {
        guard let request = pendingRequests.removeValue(forKey: requestID) else { return }
        request.continuation.resume(throwing: CodexAppServerClientError.requestTimedOut)
    }

    private func timeOutTurn(threadID: String) async {
        guard let turn = activeTurns.removeValue(forKey: threadID) else { return }
        turn.continuation.resume(throwing: CodexAppServerClientError.requestTimedOut)
        if let turnID = turn.turnID {
            await interrupt(turnID: turnID, threadID: threadID)
        }
        await unsubscribe(threadID: threadID)
    }

    private func cancelRequest(_ requestID: Int) {
        guard let request = pendingRequests.removeValue(forKey: requestID) else { return }
        request.continuation.resume(throwing: CancellationError())
    }

    private func stopProcess() {
        runningProcess = nil
        isInitialized = false
        startupTask = nil
        configuredMCPServerNames = []
    }

    private var standardErrorDescription: String? {
        let value = String(decoding: standardErrorBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.suffix(1_000))
    }

    private static func decodeModel(_ value: CodexJSONValue) -> CodexModel? {
        guard let id = value["model"]?.stringValue ?? value["id"]?.stringValue else {
            return nil
        }
        return CodexModel(
            id: id,
            displayName: value["displayName"]?.stringValue ?? id,
            isDefault: value["isDefault"]?.boolValue ?? false
        )
    }

    static func shouldResetProcess(after error: Error) -> Bool {
        guard let error = error as? CodexAppServerClientError else { return false }
        return switch error {
        case .processExited, .invalidResponse:
            true
        default:
            false
        }
    }

    private static func resolveExecutable(_ configuredURL: URL?) throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let configuredURL {
            candidates.append(configuredURL)
        } else {
            if let configuredPath = ProcessInfo.processInfo.environment["PLAINWORD_CODEX_PATH"],
               !configuredPath.isEmpty {
                candidates.append(URL(fileURLWithPath: configuredPath))
            }
            let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
                .split(separator: ":")
                .map(String.init) ?? []
            candidates += pathDirectories.map {
                URL(fileURLWithPath: $0).appendingPathComponent("codex")
            }
            candidates += [
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
            ]
        }

        var seen: Set<String> = []
        for candidate in candidates where seen.insert(candidate.path).inserted {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            guard fileManager.isExecutableFile(atPath: candidate.path) else {
                if configuredURL != nil {
                    throw CodexAppServerClientError.cliNotExecutable(candidate.path)
                }
                continue
            }
            return candidate
        }
        throw CodexAppServerClientError.cliNotFound
    }

    private static func prettyJSON(_ value: CodexJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return "<unavailable>"
        }
        return String(decoding: formatted, as: UTF8.self)
    }
}
