import Foundation
import ThermalCore

/// The real sensor suite: pressure, IOReport clocks, SMC temps/fans/power, and oMLX token speed.
public final class LiveSensors: SensorSuite {
    private let pressure = PressureSource()
    private let clocks: ClockSource
    private let smc: SMCSource?
    private var token: TokenSource?
    private var rate = TokenRateTracker()

    public let tableMax: [Cluster: Double]
    public private(set) var unavailable: Set<String> = []
    public private(set) var lastActivity: ActivitySnapshot?

    public init(tokenConfig: TokenSource.Config?) {
        clocks = ClockSource()
        smc = SMCSource()
        tableMax = clocks.tables.maxByCluster
        token = tokenConfig.map { TokenSource(config: $0) }
    }

    public var omlxBusy: Bool { (lastActivity?.activeRequests ?? 0) > 0 }
    public var tokenError: String? { token?.lastError }

    public func updateTokenConfig(_ config: TokenSource.Config?) {
        guard config != token?.config else { return }
        token = config.map { TokenSource(config: $0) }
        rate = TokenRateTracker()
        lastActivity = nil
    }

    public func read(now: Double) async -> Sample {
        var s = Sample(timestamp: now)
        var missing = Set<String>()

        s.pressure = pressure.read()
        if s.pressure == nil { missing.insert("pressure") }

        if let c = clocks.read(now: now) {
            s.superMHz = c.superMHz
            s.perfMHz = c.perfMHz
            s.gpuMHz = c.gpuMHz
            s.superBusy = c.superBusy
            s.perfBusy = c.perfBusy
            s.gpuBusy = c.gpuBusy
            s.gpuThermalCapped = c.gpuThermalCapped
            s.gpuWatts = c.gpuWatts
        } else if !clocks.available {
            missing.insert("clocks")
        }

        if let smc {
            let r = smc.read()
            s.cpuTempC = r.cpuTempC
            s.gpuTempC = r.gpuTempC
            s.fanRPM = r.fanRPM
            s.cpuWatts = r.cpuWatts
            s.systemWatts = r.systemWatts
            if r.cpuTempC == nil && r.gpuTempC == nil { missing.insert("temps") }
            if r.fanRPM.isEmpty { missing.insert("fans") }
            if r.cpuWatts == nil && r.systemWatts == nil { missing.insert("power") }
        } else {
            missing.formUnion(["temps", "fans", "power"])
        }

        if let token {
            let snapshot = await token.fetch()
            lastActivity = snapshot
            s.tokensPerSec = rate.update(snapshot, now: now)
            if snapshot == nil { missing.insert("tokens") }
        } else {
            missing.insert("tokens")
        }

        unavailable = missing
        return s
    }
}
