import Foundation
import XCTest
@testable import PlainwordCore

final class OllamaClientTests: XCTestCase {
    override func tearDown() {
        OllamaURLProtocol.handler = nil
        super.tearDown()
    }

    func testLoadsUniqueSortedModelsFromLocalTagsEndpoint() async throws {
        let client = makeClient()
        OllamaURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/tags")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let body = #"{"models":[{"name":"qwen3:8b"},{"name":"gemma3:4b"},{"name":"qwen3:8b"},{"name":"  "}]}"#
            return (response, Data(body.utf8))
        }

        let models = try await client.models()

        XCTAssertEqual(models, ["gemma3:4b", "qwen3:8b"])
    }

    func testSurfacesOllamaServerFailure() async {
        let client = makeClient()
        OllamaURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )
            )
            return (response, Data())
        }

        do {
            _ = try await client.models()
            XCTFail("Expected a server error")
        } catch {
            XCTAssertEqual(error as? OllamaClientError, .server(statusCode: 503))
        }
    }

    private func makeClient() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaURLProtocol.self]
        return OllamaClient(session: URLSession(configuration: configuration))
    }
}

private final class OllamaURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
