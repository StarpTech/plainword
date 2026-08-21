import Foundation
import Darwin
import XCTest
@testable import PlainwordCore

final class CodexAppServerClientTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainwordCodexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testKeepsAppServerAliveAcrossStatusAndCorrectionCalls() async throws {
        let launchLog = temporaryDirectory.appendingPathComponent("launch.log")
        let executable = try makeFakeCodex(launchLog: launchLog)
        let client = CodexAppServerClient(
            executableURL: executable,
            requestTimeout: 2
        )

        let firstStatus: CodexProviderStatus
        let secondStatus: CodexProviderStatus
        let correction: CorrectionResponse
        do {
            firstStatus = try await client.status()
            secondStatus = try await client.status()
            correction = try await client.correct(
                text: "This is an connection test.",
                profile: WritingProfile(),
                locale: "en-US",
                settings: LLMSettings(provider: .codex, codexModel: "test-model")
            )
        } catch {
            let transcript = (try? String(contentsOf: launchLog, encoding: .utf8)) ?? ""
            XCTFail("\(error)\n\(transcript)")
            return
        }

        XCTAssertEqual(firstStatus, secondStatus)
        XCTAssertEqual(firstStatus.email, "writer@example.com")
        XCTAssertEqual(firstStatus.planType, "plus")
        XCTAssertEqual(
            firstStatus.models,
            [CodexModel(id: "test-model", displayName: "Test Model", isDefault: true)]
        )
        XCTAssertEqual(correction.correctedText, "This is a connection test.")
        XCTAssertEqual(correction.classification, .correction)

        let transcript = try String(contentsOf: launchLog, encoding: .utf8)
        let launches = transcript
            .split(whereSeparator: \.isNewline)
            .filter { $0 == "launch" }
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(transcript.contains("\"test-mcp\":{\"enabled\":false}"))
    }

    func testShutdownTerminatesAppServerAndPreventsRestart() async throws {
        let launchLog = temporaryDirectory.appendingPathComponent("launch.log")
        let executable = try makeFakeCodex(launchLog: launchLog)
        let client = CodexAppServerClient(
            executableURL: executable,
            requestTimeout: 2
        )

        _ = try await client.status()
        await client.shutdown()
        await client.shutdown()

        let didTerminate = await waitForLogEntry("terminate", in: launchLog)
        XCTAssertTrue(didTerminate)

        do {
            _ = try await client.status()
            XCTFail("A shut-down client must not relaunch Codex")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let transcript = try String(contentsOf: launchLog, encoding: .utf8)
        let launches = transcript
            .split(whereSeparator: \.isNewline)
            .filter { $0 == "launch" }
        XCTAssertEqual(launches.count, 1)
    }

    func testRestartsAppServerAfterItWasKilledWhileIdle() async throws {
        let launchLog = temporaryDirectory.appendingPathComponent("launch.log")
        let executable = try makeFakeCodex(launchLog: launchLog)
        let client = CodexAppServerClient(
            executableURL: executable,
            requestTimeout: 2
        )

        _ = try await client.status()
        let processID = try XCTUnwrap(lastProcessID(in: launchLog))
        XCTAssertEqual(Darwin.kill(processID, SIGTERM), 0)
        let didTerminate = await waitForLogEntry("terminate", in: launchLog)
        XCTAssertTrue(didTerminate)

        let status = try await client.status()
        XCTAssertEqual(status.email, "writer@example.com")

        let transcript = try String(contentsOf: launchLog, encoding: .utf8)
        let launches = transcript
            .split(whereSeparator: \.isNewline)
            .filter { $0 == "launch" }
        XCTAssertEqual(launches.count, 2)

        await client.shutdown()
    }

    func testCodexSettingsUseAppServerWithoutCredentials() {
        let settings = LLMSettings(
            provider: .codex,
            endpoint: "https://unused.example.com",
            model: "unused-model",
            codexModel: "gpt-codex-test",
            authentication: .bearer
        )

        XCTAssertEqual(settings.resolvedEndpoint, LLMProvider.codexAppServerEndpoint)
        XCTAssertEqual(settings.resolvedModel, "gpt-codex-test")
        XCTAssertEqual(settings.resolvedAuthentication, .none)
    }

    func testTurnUsesEphemeralReadOnlyThreadAndStrictOutputSchema() {
        let thread = CodexAppServerClient.threadParameters(
            systemPrompt: "Edit text.",
            model: "test-model",
            disabledMCPServerNames: ["railway", "openaiDeveloperDocs"]
        )
        let turn = CodexAppServerClient.turnParameters(
            threadID: "thread-1",
            userPrompt: "Fix this.",
            intent: .correct,
            thinkingMode: .low
        )

        XCTAssertEqual(thread["ephemeral"], .bool(true))
        XCTAssertEqual(thread["sandbox"], .string("read-only"))
        XCTAssertEqual(thread["approvalPolicy"], .string("never"))
        XCTAssertEqual(thread["model"], .string("test-model"))
        XCTAssertEqual(thread["config"]?["features"]?["apps"], .bool(false))
        XCTAssertEqual(thread["config"]?["features"]?["multi_agent"], .bool(false))
        XCTAssertEqual(thread["config"]?["features"]?["shell_tool"], .bool(false))
        XCTAssertEqual(thread["developerInstructions"], .string(""))
        XCTAssertEqual(thread["personality"], .string("none"))
        XCTAssertEqual(thread["config"]?["include_apps_instructions"], .bool(false))
        XCTAssertEqual(
            thread["config"]?["include_collaboration_mode_instructions"],
            .bool(false)
        )
        XCTAssertEqual(thread["config"]?["include_environment_context"], .bool(false))
        XCTAssertEqual(thread["config"]?["include_permissions_instructions"], .bool(false))
        XCTAssertEqual(thread["config"]?["skills"]?["include_instructions"], .bool(false))
        XCTAssertEqual(thread["config"]?["skills"]?["bundled"]?["enabled"], .bool(false))
        XCTAssertEqual(thread["config"]?["web_search"], .string("disabled"))
        XCTAssertEqual(
            thread["config"]?["mcp_servers"]?["railway"]?["enabled"],
            .bool(false)
        )
        XCTAssertEqual(
            thread["config"]?["mcp_servers"]?["openaiDeveloperDocs"]?["enabled"],
            .bool(false)
        )
        XCTAssertEqual(turn["effort"], .string("low"))
        XCTAssertEqual(
            turn["outputSchema"]?["properties"]?["classification"]?["enum"],
            .array([.string("correction"), .string("rewrite")])
        )
    }

    func testOffThinkingModeSendsNoneEffortInsteadOfCLIConfiguration() {
        let turn = CodexAppServerClient.turnParameters(
            threadID: "thread-1",
            userPrompt: "Fix this.",
            intent: .correct,
            thinkingMode: .off
        )

        XCTAssertEqual(turn["effort"], .string("none"))
        XCTAssertEqual(CodexAppServerClient.reasoningEffort(for: .off), "none")
    }

    func testPassesExtendedReasoningEffortsThrough() {
        XCTAssertEqual(CodexAppServerClient.reasoningEffort(for: .extraHigh), "xhigh")
        XCTAssertEqual(CodexAppServerClient.reasoningEffort(for: .max), "max")
        XCTAssertEqual(
            CodexAppServerClient.turnParameters(
                threadID: "thread-1",
                userPrompt: "Fix this.",
                intent: .correct,
                thinkingMode: .extraHigh
            )["effort"],
            .string("xhigh")
        )
    }

    func testIdentifiesLatencyOptimizedModel() {
        let spark = CodexModel(
            id: CodexModel.latencyOptimizedModelID,
            displayName: "Codex Spark",
            isDefault: false
        )
        let other = CodexModel(
            id: "other-model",
            displayName: "Other",
            isDefault: true
        )

        XCTAssertTrue(spark.isLatencyOptimized)
        XCTAssertFalse(other.isLatencyOptimized)
    }

    func testTimeoutDoesNotResetAndRetryTheProcess() {
        XCTAssertFalse(
            CodexAppServerClient.shouldResetProcess(
                after: CodexAppServerClientError.requestTimedOut
            )
        )
        XCTAssertTrue(
            CodexAppServerClient.shouldResetProcess(
                after: CodexAppServerClientError.processExited(status: 1, details: nil)
            )
        )
    }

    func testRealCodexSubscriptionWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PLAINWORD_RUN_CODEX_INTEGRATION"] == "1"
        else {
            throw XCTSkip("Set PLAINWORD_RUN_CODEX_INTEGRATION=1 to use the signed-in Codex CLI.")
        }
        let client = CodexAppServerClient(requestTimeout: 30)

        let status = try await client.status()
        let correction = try await client.correct(
            text: "This are a real integration test.",
            profile: WritingProfile(),
            locale: "en-US",
            settings: LLMSettings(provider: .codex, thinkingMode: .low)
        )

        XCTAssertFalse(status.models.isEmpty)
        XCTAssertEqual(correction.correctedText, "This is a real integration test.")
        XCTAssertEqual(correction.classification, .correction)
    }

    private func makeFakeCodex(launchLog: URL) throws -> URL {
        let executable = temporaryDirectory.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        trap 'echo terminate >> '\''\(launchLog.path)'\''; exit 0' TERM
        echo launch >> '\(launchLog.path)'
        echo "pid $$" >> '\(launchLog.path)'
        while IFS= read -r line; do
          echo "$line" >> '\(launchLog.path)'
          request_id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$line" in
            *'"method":"initialize"'*)
              printf '{"id":%s,"result":{}}\\n' "$request_id"
              ;;
            *'"method":"config/read"'*)
              printf '{"id":%s,"result":{"config":{"mcp_servers":{"test-mcp":{"enabled":true}}},"origins":{}}}\\n' "$request_id"
              ;;
            *'"method":"account/read"'*)
              printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"writer@example.com","planType":"plus"},"requiresOpenaiAuth":true}}\\n' "$request_id"
              ;;
            *'"method":"model/list"'*)
              printf '{"id":%s,"result":{"data":[{"id":"test-model","model":"test-model","displayName":"Test Model","isDefault":true}],"nextCursor":null}}\\n' "$request_id"
              ;;
            *'"method":"thread/start"'*)
              printf '{"id":%s,"result":{"thread":{"id":"thread-1"}}}\\n' "$request_id"
              ;;
            *'"method":"turn/start"'*)
              printf '{"id":%s,"result":{"turn":{"id":"turn-1"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","delta":"{\\"corrected_text\\":\\"This is a connection test.\\",\\"classification\\":\\"correction\\"}"}}'
              printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-1","turnId":"turn-1","tokenUsage":{"last":{"inputTokens":42,"outputTokens":9,"totalTokens":51,"cachedInputTokens":20,"cacheWriteInputTokens":0},"total":{"inputTokens":42,"outputTokens":9,"totalTokens":51,"cachedInputTokens":20,"cacheWriteInputTokens":0}}}}'
              printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":1,"item":{"id":"item-1","type":"agentMessage","text":"{\\"corrected_text\\":\\"This is a connection test.\\",\\"classification\\":\\"correction\\"}","phase":"final_answer"}}}'
              printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","items":[]}}}'
              ;;
            *'"method":"thread/unsubscribe"'*)
              printf '{"id":%s,"result":{}}\\n' "$request_id"
              ;;
            *'"method":"turn/interrupt"'*)
              printf '{"id":%s,"result":{}}\\n' "$request_id"
              ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func lastProcessID(in log: URL) -> pid_t? {
        guard let contents = try? String(contentsOf: log, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).last(where: {
                  $0.hasPrefix("pid ")
              }),
              let processID = Int32(line.dropFirst(4)) else {
            return nil
        }
        return processID
    }

    private func waitForLogEntry(
        _ entry: String,
        in log: URL,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: log, encoding: .utf8),
               contents.split(whereSeparator: \.isNewline).contains(Substring(entry)) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
