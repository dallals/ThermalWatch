import Foundation
import ThermalCore

/// Polls oMLX's live activity. Read-only; errors never include the key or the response body.
public final class TokenSource: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var baseURL: URL
        public var bearer: String?
        public init(baseURL: URL = URL(string: "http://127.0.0.1:8901")!, bearer: String? = nil) {
            self.baseURL = baseURL
            self.bearer = bearer
        }
    }

    public let config: Config
    private let session: URLSession
    private let errorLock = NSLock()
    private var _lastError: String?
    public private(set) var lastError: String? {
        get { errorLock.lock(); defer { errorLock.unlock() }; return _lastError }
        set { errorLock.lock(); defer { errorLock.unlock() }; _lastError = newValue }
    }

    public init(config: Config, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 0.8
            c.timeoutIntervalForResource = 0.8
            self.session = URLSession(configuration: c)
        }
    }

    public func fetch() async -> ActivitySnapshot? {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("admin/api/activity"))
        request.timeoutInterval = 0.8
        if let bearer = config.bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Unexpected response"
                return nil
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return nil
            }
            let snapshot = try ActivitySnapshot.decode(data)
            lastError = nil
            return snapshot
        } catch let error as URLError {
            lastError = "Unreachable (\(error.code.rawValue))"
            return nil
        } catch {
            lastError = "Unexpected response"
            return nil
        }
    }
}
