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
