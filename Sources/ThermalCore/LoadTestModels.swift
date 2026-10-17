import Foundation

public enum LoadKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case cpu, gpu, both
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .both: "CPU + GPU"
        }
    }
}

public enum StopReason: String, Codable, Sendable {
    case finished, userStopped, tooHot, appQuit
    public var label: String {
        switch self {
        case .finished: "Finished"
        case .userStopped: "Stopped"
        case .tooHot: "Stopped: die above 105 °C"
        case .appQuit: "Stopped: app quit"
        }
    }
}

public struct LoadTestResult: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64?
    public var startedAt: Double
    public var kind: LoadKind
    public var plannedSeconds: Double
    public var ranSeconds: Double
    /// Seconds from start to the first throttled sample; nil = did not throttle.
    public var secondsToThrottle: Double?
    /// `Cluster.rawValue` → fraction below the reference peak over the last 60 s.
    public var steadyDrop: [String: Double]
    public var peakCPUTempC: Double?
    public var peakGPUTempC: Double?
    public var startWatts: Double?
    public var endWatts: Double?
    public var stopReason: StopReason
    public var note: String

    public init(id: Int64?, startedAt: Double, kind: LoadKind, plannedSeconds: Double, ranSeconds: Double,
                secondsToThrottle: Double?, steadyDrop: [String: Double], peakCPUTempC: Double?, peakGPUTempC: Double?,
                startWatts: Double?, endWatts: Double?, stopReason: StopReason, note: String) {
        self.id = id
        self.startedAt = startedAt
        self.kind = kind
        self.plannedSeconds = plannedSeconds
        self.ranSeconds = ranSeconds
        self.secondsToThrottle = secondsToThrottle
        self.steadyDrop = steadyDrop
        self.peakCPUTempC = peakCPUTempC
        self.peakGPUTempC = peakGPUTempC
        self.startWatts = startWatts
        self.endWatts = endWatts
        self.stopReason = stopReason
        self.note = note
    }
}
