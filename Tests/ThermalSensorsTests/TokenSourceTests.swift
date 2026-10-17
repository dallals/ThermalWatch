import Foundation
import Testing
@testable import ThermalCore
@testable import ThermalSensors

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (code, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

private let body = Data(#"{"active_models": {"total_active_requests": 1, "models": [{"generating": [{"request_id": "a", "generated_tokens": 7, "elapsed_seconds": 1.0}]}]}}"#.utf8)

@Suite(.serialized) struct TokenSourceTests {
    @Test func fetchDecodesActivityWithoutAuthByDefault() async {
        var seenPath: String?
        var seenAuth: String?
        StubProtocol.handler = { req in
            seenPath = req.url?.path
            seenAuth = req.value(forHTTPHeaderField: "Authorization")
            return (200, body)
        }
        let source = TokenSource(config: .init(), session: stubSession())
        let snap = await source.fetch()
        #expect(snap?.activeRequests == 1)
        #expect(snap?.generating.first?.tokens == 7)
        #expect(seenPath == "/admin/api/activity")
        #expect(seenAuth == nil)
        #expect(source.lastError == nil)
    }

    @Test func bearerIsSentButNeverReported() async {
        var seenAuth: String?
        StubProtocol.handler = { req in
            seenAuth = req.value(forHTTPHeaderField: "Authorization")
            return (401, Data("{\"detail\":\"sekrit-key bad\"}".utf8))
        }
        let source = TokenSource(config: .init(bearer: "sekrit-key"), session: stubSession())
        #expect(await source.fetch() == nil)
        #expect(seenAuth == "Bearer sekrit-key")
        #expect(source.lastError == "HTTP 401")
    }

    @Test func badBodyGivesNil() async {
        StubProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        let source = TokenSource(config: .init(), session: stubSession())
        #expect(await source.fetch() == nil)
        #expect(source.lastError == "Unexpected response")
    }

    @Test func unreachableServerReturnsNilQuickly() async {
        let source = TokenSource(config: .init(baseURL: URL(string: "http://127.0.0.1:9")!))
        let start = Date()
        #expect(await source.fetch() == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(source.lastError?.hasPrefix("Unreachable") == true)
    }
}
