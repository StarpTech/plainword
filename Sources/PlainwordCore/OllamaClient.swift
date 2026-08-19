import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OllamaClientError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidResponse
    case server(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Couldn’t reach Ollama. Make sure it is running on this Mac."
        case .invalidResponse:
            "Ollama returned an unreadable model list."
        case .server(let statusCode):
            "Ollama returned HTTP \(statusCode) while loading models."
        }
    }
}

private struct OllamaModelsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
}

public struct OllamaClient: Sendable {
    public static let defaultModelsURL = URL(string: "http://localhost:11434/api/tags")!

    private let session: URLSession
    private let timeout: TimeInterval
    private let modelsURL: URL

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 5,
        modelsURL: URL = OllamaClient.defaultModelsURL
    ) {
        self.session = session
        self.timeout = timeout
        self.modelsURL = modelsURL
    }

    public func models() async throws -> [String] {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Plainword/1", forHTTPHeaderField: "X-Plainword-Client")

        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OllamaClientError.unavailable
        }

        guard let response = rawResponse as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OllamaClientError.server(statusCode: response.statusCode)
        }
        guard let result = try? JSONDecoder().decode(OllamaModelsResponse.self, from: data) else {
            throw OllamaClientError.invalidResponse
        }

        return Array(
            Set(
                result.models.compactMap { model in
                    let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return name.isEmpty ? nil : name
                }
            )
        )
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
