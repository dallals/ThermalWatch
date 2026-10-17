import Foundation
import IOKit
import ThermalCore

public struct ClusterTables: Equatable, Sendable {
    public var superMHz: [Double]
    public var perfMHz: [Double]
    public var gpuMHz: [Double]

    public init(superMHz: [Double] = [], perfMHz: [Double] = [], gpuMHz: [Double] = []) {
        self.superMHz = superMHz
        self.perfMHz = perfMHz
        self.gpuMHz = gpuMHz
    }

    public var maxByCluster: [Cluster: Double] {
        var m: [Cluster: Double] = [:]
        if let v = superMHz.max(), v > 0 { m[.superCores] = v }
        if let v = perfMHz.max(), v > 0 { m[.performance] = v }
        if let v = gpuMHz.max(), v > 0 { m[.gpu] = v }
        return m
    }
}

public enum PMGR {
    /// Reads the M5 Max frequency tables from the `pmgr` IORegistry node. Missing tables stay empty.
    public static func readTables() -> ClusterTables {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &iterator) == KERN_SUCCESS else {
            return ClusterTables()
        }
        defer { IOObjectRelease(iterator) }
        var tables = ClusterTables()
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func blob(_ key: String) -> Data? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
            }
            if let d = blob("voltage-states5-sram") { tables.superMHz = FrequencyTable.decode(d, divisor: 1_000) }
            if let d = blob("voltage-states22-sram") { tables.perfMHz = FrequencyTable.decode(d, divisor: 1_000) }
            if let d = blob("voltage-states9") { tables.gpuMHz = FrequencyTable.decode(d, divisor: 1_000_000) }
        }
        return tables
    }
}
