import Combine
import Foundation
import PlainwordCore

struct LLMDebugLogEntry: Identifiable {
    enum State: Equatable {
        case inProgress
        case succeeded(statusCode: Int)
        case failed(statusCode: Int?, message: String)
    }

    let request: LLMCallDebugRequest
    var firstByteAt: Date?
    var completedAt: Date?
    var state: State
    /// The model's thinking, assembled from however many pieces the provider sent.
    /// `nil` when it reported none, which is most providers and every model with
    /// thinking turned off.
    var reasoning: String?
    var responseBody: String?
    var tokenUsage: LLMTokenUsage?

    var id: UUID { request.id }

    var duration: TimeInterval? {
        completedAt?.timeIntervalSince(request.startedAt)
    }

    /// How long the provider took to say anything at all.
    var timeToFirstByte: TimeInterval? {
        firstByteAt?.timeIntervalSince(request.startedAt)
    }
}

@MainActor
final class LLMDebugLogStore: ObservableObject {
    @Published private(set) var entries: [LLMDebugLogEntry] = []

    private let maximumEntryCount: Int

    /// Thinking can run longer than the answer several times over, and a hundred calls
    /// are held in memory at once, so it is kept to the same ceiling as a response body.
    private static let maximumReasoningCharacterCount = 65_536

    init(maximumEntryCount: Int = 100) {
        self.maximumEntryCount = maximumEntryCount
    }

    func record(_ event: LLMCallDebugEvent) {
        switch event {
        case .started(let request):
            entries.removeAll { $0.id == request.id }
            entries.insert(
                LLMDebugLogEntry(
                    request: request,
                    firstByteAt: nil,
                    completedAt: nil,
                    state: .inProgress,
                    reasoning: nil,
                    responseBody: nil,
                    tokenUsage: nil
                ),
                at: 0
            )
            if entries.count > maximumEntryCount {
                entries.removeLast(entries.count - maximumEntryCount)
            }

        case let .firstByte(id, at):
            guard let index = entries.firstIndex(where: { $0.id == id }),
                  entries[index].firstByteAt == nil else { return }
            entries[index].firstByteAt = at

        case let .reasoning(id, delta):
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            let existing = entries[index].reasoning ?? ""
            let limit = Self.maximumReasoningCharacterCount
            guard existing.count < limit else { return }
            let appended = existing + delta
            entries[index].reasoning = appended.count <= limit
                ? appended
                : String(appended.prefix(limit)) + "\n\n… thinking truncated …"

        case let .succeeded(id, completedAt, statusCode, responseBody, tokenUsage):
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].completedAt = completedAt
            entries[index].state = .succeeded(statusCode: statusCode)
            entries[index].responseBody = responseBody
            entries[index].tokenUsage = tokenUsage

        case let .failed(id, completedAt, statusCode, error, responseBody, tokenUsage):
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].completedAt = completedAt
            entries[index].state = .failed(statusCode: statusCode, message: error)
            entries[index].responseBody = responseBody
            entries[index].tokenUsage = tokenUsage
        }
    }

    func clear() {
        entries.removeAll()
    }
}
