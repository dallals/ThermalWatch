import Foundation

public enum Cluster: String, CaseIterable, Codable, Sendable {
    case superCores = "super"
    case performance = "perf"
    case gpu = "gpu"

    public var label: String {
        switch self {
        case .superCores: "Super"
        case .performance: "Perf"
        case .gpu: "GPU"
        }
    }
}

public enum ThrottleState: Int, Codable, Sendable, Comparable {
    case cool = 0
    case warm = 1
    case throttled = 2

    public static func < (lhs: ThrottleState, rhs: ThrottleState) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .cool: "COOL"
        case .warm: "WARM"
        case .throttled: "THROTTLED"
        }
    }
}

public enum PressureLevel: Int, CaseIterable, Sendable {
    case nominal = 0, moderate, heavy, trapping, sleeping

    public var label: String {
        switch self {
        case .nominal: "Nominal"
        case .moderate: "Moderate"
        case .heavy: "Heavy"
        case .trapping: "Trapping"
        case .sleeping: "Sleeping"
        }
    }
}

/// One reading of every source, taken once per second. A failed source leaves its fields nil.
public struct Sample: Codable, Equatable, Sendable {
    public var timestamp: Double
    public var pressure: Int?
    public var superMHz: Double?
    public var perfMHz: Double?
    public var gpuMHz: Double?
    public var superBusy: Double?
    public var perfBusy: Double?
    public var gpuBusy: Double?
    public var gpuThermalCapped: Bool?
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var systemWatts: Double?
    public var cpuTempC: Double?
    public var gpuTempC: Double?
    public var fanRPM: [Double] = []
    public var tokensPerSec: Double?
    public var state: ThrottleState = .cool
    public var clockLimited: Bool = false

    public init(timestamp: Double, pressure: Int? = nil) {
        self.timestamp = timestamp
        self.pressure = pressure
    }

    public func mhz(_ cluster: Cluster) -> Double? {
        switch cluster {
        case .superCores: superMHz
        case .performance: perfMHz
        case .gpu: gpuMHz
        }
    }

    public func busy(_ cluster: Cluster) -> Double? {
        switch cluster {
        case .superCores: superBusy
        case .performance: perfBusy
        case .gpu: gpuBusy
        }
    }

    /// Whether this cluster's clock says anything about heat in this sample. The GPU's clock follows demand
    /// (it sits at its lowest state between bursts of work while still counted as busy), so a low GPU clock
    /// only counts while the GPU thermal cap is on.
    public func clockReflectsHeat(_ cluster: Cluster) -> Bool {
        cluster != .gpu || gpuThermalCapped == true
    }
}
