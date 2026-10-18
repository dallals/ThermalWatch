import Foundation

public struct ThrottleEvent: Codable, Equatable, Sendable, Identifiable {
    public var start: Double
    public var end: Double
    public var worstPressure: Int
    /// Largest fraction below the reference peak among busy clusters (0–1).
    public var maxClockDrop: Double
    public var tokensBefore: Double?
    public var tokensDuring: Double?

    public init(start: Double, end: Double, worstPressure: Int, maxClockDrop: Double, tokensBefore: Double?, tokensDuring: Double?) {
        self.start = start
        self.end = end
        self.worstPressure = worstPressure
        self.maxClockDrop = maxClockDrop
        self.tokensBefore = tokensBefore
        self.tokensDuring = tokensDuring
    }

    public var id: Double { start }
    public var duration: Double { end - start + 1 }
}

/// Groups consecutive throttled samples into events; an event closes after `closeAfter` seconds without throttling.
public struct EventBuilder: Sendable {
    public var closeAfter: Double
    public var busyThreshold: Double
    public private(set) var current: ThrottleEvent?
    private var lastThrottled: Double = 0
    private var before: [TimedValue] = []
    private var during: [Double] = []

    private struct TimedValue: Sendable {
        var t: Double
        var value: Double
    }

    public init(closeAfter: Double = 10, busyThreshold: Double = Thresholds.standard.busy) {
        self.closeAfter = closeAfter
        self.busyThreshold = busyThreshold
    }

    public static func clockDrop(_ s: Sample, peaks: [Cluster: Double], busyThreshold: Double) -> Double {
        var worst = 0.0
        for cluster in Cluster.allCases where s.clockReflectsHeat(cluster) {
            guard let mhz = s.mhz(cluster), let busy = s.busy(cluster), busy > busyThreshold,
                  let peak = peaks[cluster], peak > 0 else { continue }
            worst = max(worst, 1 - mhz / peak)
        }
        return worst
    }

    /// Feed every classified sample in order, with the peaks used to classify it.
    /// Returns an event when one closes.
    public mutating func feed(_ s: Sample, peaks: [Cluster: Double]) -> ThrottleEvent? {
        var closed: ThrottleEvent?
        if current != nil, s.timestamp - lastThrottled >= closeAfter { closed = finish() }

        if s.state == .throttled {
            let drop = Self.clockDrop(s, peaks: peaks, busyThreshold: busyThreshold)
            if var e = current {
                e.end = s.timestamp
                e.worstPressure = max(e.worstPressure, s.pressure ?? 0)
                e.maxClockDrop = max(e.maxClockDrop, drop)
                current = e
            } else {
                let window = before.filter { $0.t >= s.timestamp - 60 }.map(\.value)
                current = ThrottleEvent(start: s.timestamp, end: s.timestamp, worstPressure: s.pressure ?? 0,
                                        maxClockDrop: drop, tokensBefore: Self.mean(window), tokensDuring: nil)
                during = []
            }
            if let t = s.tokensPerSec { during.append(t) }
            lastThrottled = s.timestamp
        } else if current == nil, let t = s.tokensPerSec {
            before.append(TimedValue(t: s.timestamp, value: t))
        }
        before.removeAll { $0.t < s.timestamp - 60 }
        return closed
    }

    /// Closes the open event, if any (e.g. when the app quits).
    public mutating func flush() -> ThrottleEvent? {
        current == nil ? nil : finish()
    }

    private mutating func finish() -> ThrottleEvent? {
        guard var e = current else { return nil }
        e.tokensDuring = Self.mean(during)
        current = nil
        during = []
        before = []
        return e
    }

    /// Fewer readings than this make no fair before/during comparison (a reply's first seconds alone).
    static let minTokenReadings = 5

    static func mean(_ values: [Double]) -> Double? {
        values.count < minTokenReadings ? nil : values.reduce(0, +) / Double(values.count)
    }
}
