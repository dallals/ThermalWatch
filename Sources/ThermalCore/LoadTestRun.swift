import Foundation

/// Records one load-test run from the Monitor's samples and decides when it must stop.
public struct LoadTestRun: Sendable {
    public let kind: LoadKind
    public let plannedSeconds: Double
    public let startedAt: Double
    public var hotLimitC: Double = 105
    public private(set) var samples: [Sample] = []

    public init(kind: LoadKind, plannedSeconds: Double, startedAt: Double) {
        self.kind = kind
        self.plannedSeconds = plannedSeconds
        self.startedAt = startedAt
    }

    public var elapsed: Double { (samples.last?.timestamp ?? startedAt) - startedAt }

    /// Returns a reason when the run must stop now.
    public mutating func feed(_ s: Sample) -> StopReason? {
        guard s.timestamp >= startedAt else { return nil }
        samples.append(s)
        if max(s.cpuTempC ?? 0, s.gpuTempC ?? 0) > hotLimitC { return .tooHot }
        if s.timestamp - startedAt >= plannedSeconds { return .finished }
        return nil
    }

    public func clusters() -> [Cluster] {
        switch kind {
        case .cpu: [.superCores, .performance]
        case .gpu: [.gpu]
        case .both: Cluster.allCases
        }
    }

    public func result(stopReason: StopReason, endedAt: Double, peaks: [Cluster: Double], note: String) -> LoadTestResult {
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        func watts(_ s: Sample) -> Double? {
            (s.cpuWatts == nil && s.gpuWatts == nil) ? nil : (s.cpuWatts ?? 0) + (s.gpuWatts ?? 0)
        }
        let lastMinute = samples.filter { $0.timestamp > endedAt - 60 }
        var drops: [String: Double] = [:]
        for cluster in clusters() {
            guard let avg = mean(lastMinute.compactMap { $0.mhz(cluster) }), let peak = peaks[cluster], peak > 0 else { continue }
            drops[cluster.rawValue] = max(0, 1 - avg / peak)
        }
        return LoadTestResult(
            id: nil,
            startedAt: startedAt,
            kind: kind,
            plannedSeconds: plannedSeconds,
            ranSeconds: endedAt - startedAt,
            secondsToThrottle: samples.first { $0.state == .throttled }.map { $0.timestamp - startedAt },
            steadyDrop: drops,
            peakCPUTempC: samples.compactMap(\.cpuTempC).max(),
            peakGPUTempC: samples.compactMap(\.gpuTempC).max(),
            startWatts: mean(samples.filter { $0.timestamp < startedAt + 30 }.compactMap(watts)),
            endWatts: mean(samples.filter { $0.timestamp > endedAt - 30 }.compactMap(watts)),
            stopReason: stopReason,
            note: note
        )
    }
}
