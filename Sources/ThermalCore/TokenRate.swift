import Foundation

public struct GeneratingRequest: Equatable, Sendable {
    public var id: String
    public var tokens: Int
    public var elapsed: Double?
    public init(id: String, tokens: Int, elapsed: Double?) {
        self.id = id
        self.tokens = tokens
        self.elapsed = elapsed
    }
}

/// The parts of oMLX `/admin/api/activity` the app uses. Nothing else is decoded.
public struct ActivitySnapshot: Equatable, Sendable {
    public var activeRequests: Int
    public var generating: [GeneratingRequest]

    public init(activeRequests: Int, generating: [GeneratingRequest]) {
        self.activeRequests = activeRequests
        self.generating = generating
    }

    public enum DecodeError: Error { case shape }

    public static func decode(_ data: Data) throws -> ActivitySnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["active_models"] as? [String: Any] else { throw DecodeError.shape }
        var generating: [GeneratingRequest] = []
        for model in (models["models"] as? [[String: Any]]) ?? [] {
            for g in (model["generating"] as? [[String: Any]]) ?? [] {
                guard let id = g["request_id"] as? String else { continue }
                generating.append(GeneratingRequest(id: id, tokens: (g["generated_tokens"] as? Int) ?? 0, elapsed: g["elapsed_seconds"] as? Double))
            }
        }
        return ActivitySnapshot(activeRequests: (models["total_active_requests"] as? Int) ?? 0, generating: generating)
    }
}

/// Live generation speed from successive activity polls (spec "Token speed").
public struct TokenRateTracker: Sendable {
    private var lastTokens: [String: Int] = [:]
    private var lastTime: Double?

    public init() {}

    public mutating func update(_ snapshot: ActivitySnapshot?, now: Double) -> Double? {
        guard let snapshot else {
            lastTokens = [:]
            lastTime = nil
            return nil
        }
        let previous = lastTokens
        let previousTime = lastTime
        lastTokens = Dictionary(snapshot.generating.map { ($0.id, $0.tokens) }, uniquingKeysWith: { max($0, $1) })
        lastTime = now
        guard let previousTime, now > previousTime, !snapshot.generating.isEmpty else { return nil }
        let dt = now - previousTime
        var total = 0
        for r in snapshot.generating {
            if let before = previous[r.id] {
                total += max(0, r.tokens - before)
            } else if let elapsed = r.elapsed, elapsed <= dt {
                total += r.tokens
            }
        }
        return Double(total) / dt
    }
}
