import Foundation
import Testing
@testable import ThermalSensors

private func st(_ pairs: [(String, Int64)]) -> [StateResidency] {
    pairs.map { StateResidency(name: $0.0, ticks: $0.1) }
}

private func ch(_ group: String, _ sub: String, _ name: String, _ states: [(String, Int64)], unit: String = "24Mticks", value: Int64 = 0) -> IOReportChannelReading {
    IOReportChannelReading(group: group, subgroup: sub, channel: name, unit: unit, states: st(states), value: value)
}

private let cluster = "CPU Complex Performance States"
private let core = "CPU Core Performance States"

@Test func readingCombinesClustersCoresGPUAndEnergy() {
    let tables = ClusterTables(superMHz: [1000, 2000, 4000], perfMHz: [1000, 3000], gpuMHz: [0, 400, 1600])
    let readings = [
        ch("CPU Stats", cluster, "PCPU", [("IDLE", 50), ("V2P0", 50)]),
        ch("CPU Stats", core, "PCPU0", [("IDLE", 0), ("V2P0", 100)]),
        ch("CPU Stats", core, "PCPU1", [("IDLE", 100), ("V2P0", 0)]),
        ch("CPU Stats", cluster, "MCPU0", [("DOWN", 100), ("IDLE", 0), ("V1P0", 0)]),
        ch("CPU Stats", cluster, "MCPU1", [("DOWN", 0), ("IDLE", 50), ("V1P0", 50)]),
        ch("CPU Stats", core, "MCPU00", [("DOWN", 100), ("V1P0", 0)]),
        ch("CPU Stats", core, "MCPU10", [("DOWN", 0), ("V1P0", 100)]),
        ch("GPU Stats", "GPU Performance States", "GPUPH", [("OFF", 75), ("P2", 25)]),
        ch("GPU Stats", "CLTM-induced GPU Performance States", "GPU_CLTM", [("NO_CLTM", 100), ("P3", 0)]),
        ch("Energy Model", "", "GPU Energy", [], unit: "nJ", value: 3_000_000_000),
    ]
    let r = ClockSource.reading(from: readings, seconds: 2, tables: tables)
    #expect(r.superMHz == 4000)
    #expect(r.superBusy == 0.5)
    #expect(r.perfMHz == 3000)
    #expect(r.perfBusy == 0.5)
    #expect(r.gpuMHz == 1600)
    #expect(r.gpuBusy == 0.25)
    #expect(r.gpuThermalCapped == false)
    #expect(r.gpuWatts == 1.5)
}

@Test func coreBusyFallsBackToClusterWhenCoresReportNothing() {
    let tables = ClusterTables(superMHz: [1000, 2000], perfMHz: [], gpuMHz: [])
    let readings = [
        ch("CPU Stats", cluster, "PCPU", [("IDLE", 25), ("V1P0", 75)]),
        ch("CPU Stats", core, "PCPU0", [("IDLE", 100)]),
    ]
    let r = ClockSource.reading(from: readings, seconds: 1, tables: tables)
    #expect(r.superBusy == 0.75)
    #expect(r.superMHz == 2000)
    #expect(r.perfMHz == nil)
}

@Test func missingChannelsGiveNil() {
    let r = ClockSource.reading(from: [], seconds: 1, tables: ClusterTables())
    #expect(r == ClockReading())
}

@Test func smcKeyDataMatchesKernelLayout() {
    #expect(MemoryLayout<SMCKeyData>.size == 80)
}

@Test func clusterTablesMax() {
    let t = ClusterTables(superMHz: [1308, 4608], perfMHz: [1344, 4380], gpuMHz: [0, 338, 1620])
    #expect(t.maxByCluster == [.superCores: 4608, .performance: 4380, .gpu: 1620])
    #expect(ClusterTables().maxByCluster.isEmpty)
}
