import Foundation

public struct ThrottleEvent: Codable, Equatable, Sendable, Identifiable {
    public var start: Double
    public var end: Double
    public var worstPressure: Int
    /// Largest fraction below the reference peak among busy clusters (0–1), at the event's worst second.
    public var maxClockDrop: Double
    public var tokensBefore: Double?
    public var tokensDuring: Double?
    /// Median drop of `dropCluster` over the seconds it was busy; nil with too few readings.
    public var typicalClockDrop: Double?
    /// The cluster whose clock dropped furthest; nil when no busy cluster slowed.
    public var dropCluster: Cluster?

    public init(start: Double, end: Double, worstPressure: Int, maxClockDrop: Double, tokensBefore: Double?, tokensDuring: Double?,
                typicalClockDrop: Double? = nil, dropCluster: Cluster? = nil) {
        self.start = start
        self.end = end
        self.worstPressure = worstPressure
        self.maxClockDrop = maxClockDrop
        self.tokensBefore = tokensBefore
        self.tokensDuring = tokensDuring
        self.typicalClockDrop = typicalClockDrop
        self.dropCluster = dropCluster
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
    private var drops: [Cluster: [Double]] = [:]

    private struct TimedValue: Sendable {
        var t: Double
        var value: Double
    }

    public init(closeAfter: Double = 10, busyThreshold: Double = Thresholds.standard.busy) {
        self.closeAfter = closeAfter
        self.busyThreshold = busyThreshold
    }

    public static func clockDrop(_ s: Sample, peaks: [Cluster: Double], busyThreshold: Double) -> Double {
        clusterDrops(s, peaks: peaks, busyThreshold: busyThreshold).values.max() ?? 0
    }

    /// Each busy cluster's fraction below its reference peak (never below 0).
    static func clusterDrops(_ s: Sample, peaks: [Cluster: Double], busyThreshold: Double) -> [Cluster: Double] {
        var out: [Cluster: Double] = [:]
        for cluster in Cluster.allCases where s.clockReflectsHeat(cluster) {
            guard let mhz = s.mhz(cluster), let busy = s.busy(cluster), busy > busyThreshold,
                  let peak = peaks[cluster], peak > 0 else { continue }
            out[cluster] = max(0, 1 - mhz / peak)
        }
        return out
    }

    /// Feed every classified sample in order, with the peaks used to classify it.
    /// Returns an event when one closes.
    public mutating func feed(_ s: Sample, peaks: [Cluster: Double]) -> ThrottleEvent? {
        var closed: ThrottleEvent?
        if current != nil, s.timestamp - lastThrottled >= closeAfter { closed = finish() }

        if s.state == .throttled {
            let clusterDrops = Self.clusterDrops(s, peaks: peaks, busyThreshold: busyThreshold)
            let drop = clusterDrops.values.max() ?? 0
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
                drops = [:]
            }
            for (cluster, d) in clusterDrops { drops[cluster, default: []].append(d) }
            updateTypicalDrop()
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
        drops = [:]
        before = []
        return e
    }

    /// Points the open event at the cluster with the deepest drop and records that cluster's median.
    private mutating func updateTypicalDrop() {
        guard var e = current,
              let (cluster, values) = drops.max(by: { ($0.value.max() ?? 0) < ($1.value.max() ?? 0) }),
              (values.max() ?? 0) > 0 else { return }
        e.dropCluster = cluster
        e.typicalClockDrop = Self.median(values)
        current = e
    }

    /// Fewer readings than this make no fair before/during comparison (a reply's first seconds alone).
    static let minTokenReadings = 5

    static func median(_ values: [Double]) -> Double? {
        guard values.count >= minTokenReadings else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func mean(_ values: [Double]) -> Double? {
        values.count < minTokenReadings ? nil : values.reduce(0, +) / Double(values.count)
    }
}
