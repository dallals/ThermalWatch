import Foundation

public struct Thresholds: Equatable, Sendable {
    public var busy = 0.60
    public var busySeconds = 5.0
    public var throttleDrop = 0.15
    public var warmDrop = 0.05
    public var warmTempC = 95.0
    public var maxGap = 2.0

    public init() {}
    public static let standard = Thresholds()
}

public struct Classification: Equatable, Sendable {
    public var state: ThrottleState
    public var clockLimited: Bool
    public init(state: ThrottleState, clockLimited: Bool) {
        self.state = state
        self.clockLimited = clockLimited
    }
}

public struct ThrottleDetector: Sendable {
    public var thresholds: Thresholds

    public init(thresholds: Thresholds = .standard) {
        self.thresholds = thresholds
    }

    /// `recent` holds earlier samples, oldest first. `peaks` are the reference peaks in MHz.
    public func classify(current: Sample, recent: [Sample], peaks: [Cluster: Double]) -> Classification {
        var limited = current.gpuCapLimiting(peaks: peaks, thresholds: thresholds)
        var warm = false
        for cluster in Cluster.allCases where current.clockReflectsHeat(cluster) {
            guard let mhz = current.mhz(cluster), let busy = current.busy(cluster), busy > thresholds.busy,
                  let peak = peaks[cluster], peak > 0 else { continue }
            if mhz < peak * (1 - thresholds.throttleDrop) {
                if busyRunSeconds(cluster, current: current, recent: recent) >= thresholds.busySeconds {
                    limited = true
                } else {
                    warm = true
                }
            } else if mhz <= peak * (1 - thresholds.warmDrop) {
                warm = true
            }
        }
        if let t = current.cpuTempC, t > thresholds.warmTempC { warm = true }
        if let t = current.gpuTempC, t > thresholds.warmTempC { warm = true }

        if (current.pressure ?? 0) >= 1 || limited {
            return Classification(state: .throttled, clockLimited: limited)
        }
        return Classification(state: warm ? .warm : .cool, clockLimited: false)
    }

    func busyRunSeconds(_ cluster: Cluster, current: Sample, recent: [Sample]) -> Double {
        var earliest = current.timestamp
        for s in recent.reversed() {
            guard earliest - s.timestamp <= thresholds.maxGap,
                  let busy = s.busy(cluster), busy > thresholds.busy else { break }
            earliest = s.timestamp
        }
        return current.timestamp - earliest + 1
    }
}

/// Reference peak per cluster: highest clock seen while busy (from history plus live samples),
/// falling back to the frequency table's maximum.
public struct PeakTracker: Sendable {
    public let tableMax: [Cluster: Double]
    public var busyThreshold: Double
    public private(set) var observed: [Cluster: Double]

    public init(tableMax: [Cluster: Double], observed: [Cluster: Double] = [:], busyThreshold: Double = Thresholds.standard.busy) {
        self.tableMax = tableMax
        self.observed = observed
        self.busyThreshold = busyThreshold
    }

    public mutating func observe(_ s: Sample) {
        for cluster in Cluster.allCases {
            guard let mhz = s.mhz(cluster), let busy = s.busy(cluster), busy > busyThreshold else { continue }
            observed[cluster] = max(observed[cluster] ?? 0, mhz)
        }
    }

    public mutating func replaceObserved(_ values: [Cluster: Double]) {
        observed = values
    }

    public func peaks() -> [Cluster: Double] {
        var out = tableMax
        for (cluster, value) in observed where value > 0 { out[cluster] = value }
        return out
    }
}
