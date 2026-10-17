import Foundation

public struct ClockReading: Equatable, Sendable {
    public var superMHz: Double?
    public var perfMHz: Double?
    public var gpuMHz: Double?
    public var superBusy: Double?
    public var perfBusy: Double?
    public var gpuBusy: Double?
    public var gpuThermalCapped: Bool?
    public var gpuWatts: Double?
    public init() {}
}

public final class ClockSource {
    static let clusterSubgroup = "CPU Complex Performance States"
    static let coreSubgroup = "CPU Core Performance States"
    static let gpuSubgroup = "GPU Performance States"
    static let cltmSubgroup = "CLTM-induced GPU Performance States"

    public let tables: ClusterTables
    private let sampler: IOReportSampler?
    public private(set) var lastReadings: [IOReportChannelReading] = []

    public init(tables: ClusterTables = PMGR.readTables()) {
        self.tables = tables
        sampler = IOReportSampler(groups: [
            ("CPU Stats", Self.clusterSubgroup),
            ("CPU Stats", Self.coreSubgroup),
            ("GPU Stats", Self.gpuSubgroup),
            ("GPU Stats", Self.cltmSubgroup),
            ("Energy Model", nil),
        ])
    }

    public var available: Bool { sampler != nil }

    /// Clock reading for the interval since the last call; nil on the first call or when IOReport is unavailable.
    public func read(now: Double) -> ClockReading? {
        guard let sampler, let (readings, seconds) = sampler.next(now: now) else { return nil }
        lastReadings = readings
        return Self.reading(from: readings, seconds: seconds, tables: tables)
    }

    public static func reading(from readings: [IOReportChannelReading], seconds: Double, tables: ClusterTables) -> ClockReading {
        func channels(_ subgroup: String, _ match: (String) -> Bool) -> [[StateResidency]] {
            readings.filter { $0.subgroup == subgroup && match($0.channel) }.map(\.states)
        }
        func meanActive(_ cores: [[StateResidency]], fallback: Double) -> Double {
            let fractions = cores.compactMap { Residency.summarize($0, table: [])?.activeFraction }
            guard !fractions.isEmpty else { return fallback }
            let mean = fractions.reduce(0, +) / Double(fractions.count)
            return (mean == 0 && fallback > 0) ? fallback : mean
        }

        var r = ClockReading()

        let superStates = Residency.merge(channels(clusterSubgroup) { $0 == "PCPU" })
        if let s = Residency.summarize(superStates, table: tables.superMHz) {
            r.superMHz = s.averageMHz
            r.superBusy = meanActive(channels(coreSubgroup) { $0.hasPrefix("PCPU") }, fallback: s.activeFraction)
        }

        let perfStates = Residency.merge(channels(clusterSubgroup) { $0 == "MCPU0" || $0 == "MCPU1" })
        if let s = Residency.summarize(perfStates, table: tables.perfMHz) {
            r.perfMHz = s.averageMHz
            r.perfBusy = meanActive(channels(coreSubgroup) { $0.hasPrefix("MCPU") }, fallback: s.activeFraction)
        }

        let gpuStates = Residency.merge(channels(gpuSubgroup) { $0 == "GPUPH" })
        if let s = Residency.summarize(gpuStates, table: tables.gpuMHz) {
            r.gpuMHz = s.averageMHz
            r.gpuBusy = s.activeFraction
        }

        let cltm = channels(cltmSubgroup) { $0 == "GPU_CLTM" }
        if !cltm.isEmpty { r.gpuThermalCapped = Residency.thermalCapped(Residency.merge(cltm)) }

        if let energy = readings.first(where: { $0.group == "Energy Model" && $0.channel == "GPU Energy" }) {
            r.gpuWatts = Energy.watts(value: energy.value, unit: energy.unit, seconds: seconds)
        }
        return r
    }
}
