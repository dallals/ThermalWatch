import Foundation
import ThermalCore
import ThermalSensors

func show(_ v: Double?, _ unit: String, digits: Int = 0) -> String {
    v.map { String(format: "%.\(digits)f%@", $0, unit) } ?? "unavailable"
}

func check(_ label: String, _ ok: Bool) {
    print("  \(ok ? "OK  " : "WARN") \(label)")
}

let tables = PMGR.readTables()
print("Frequency tables:")
print("  Super: \(tables.superMHz.count) states, max \(show(tables.superMHz.max(), " MHz"))")
print("  Perf:  \(tables.perfMHz.count) states, max \(show(tables.perfMHz.max(), " MHz"))")
print("  GPU:   \(tables.gpuMHz.count) states, max \(show(tables.gpuMHz.max(), " MHz"))")
check("all three tables present", !tables.superMHz.isEmpty && !tables.perfMHz.isEmpty && !tables.gpuMHz.isEmpty)

let pressure = PressureSource().read()
print("Thermal pressure: \(pressure.map { "\($0) (\(PressureLevel(rawValue: $0)?.label ?? "?"))" } ?? "unavailable")")
check("pressure in 0...4", pressure != nil)

let clocks = ClockSource(tables: tables)
print("IOReport: \(clocks.available ? "subscribed" : "unavailable")")
_ = clocks.read(now: Date().timeIntervalSince1970)
Thread.sleep(forTimeInterval: 1)
if let c = clocks.read(now: Date().timeIntervalSince1970) {
    print("  Super \(show(c.superMHz, " MHz")) busy \(show(c.superBusy.map { $0 * 100 }, "%"))")
    print("  Perf  \(show(c.perfMHz, " MHz")) busy \(show(c.perfBusy.map { $0 * 100 }, "%"))")
    print("  GPU   \(show(c.gpuMHz, " MHz")) busy \(show(c.gpuBusy.map { $0 * 100 }, "%")) thermal cap \(c.gpuThermalCapped.map { "\($0)" } ?? "unavailable")")
    print("  GPU power \(show(c.gpuWatts, " W", digits: 2))")
    for (cluster, mhz) in [(Cluster.superCores, c.superMHz), (.performance, c.perfMHz), (.gpu, c.gpuMHz)] {
        if let mhz, let top = tables.maxByCluster[cluster] { check("\(cluster.label) clock within table (\(Int(mhz)) ≤ \(Int(top)))", mhz <= top + 1) }
    }
} else {
    check("clock reading", false)
}
if CommandLine.arguments.contains("--states") {
    for r in clocks.lastReadings where !r.states.isEmpty && r.group != "Energy Model" {
        print("  [\(r.subgroup)] \(r.channel): " + r.states.map { "\($0.name)=\($0.ticks)" }.joined(separator: " "))
    }
}

if let smc = SMCSource() {
    let r = smc.read()
    print("SMC: CPU \(show(r.cpuTempC, " °C", digits: 1)), GPU \(show(r.gpuTempC, " °C", digits: 1)), fans \(r.fanRPM.map { String(Int($0)) }.joined(separator: "/")) rpm")
    print("  CPU power \(show(r.cpuWatts, " W", digits: 1)), system power \(show(r.systemWatts, " W", digits: 1))")
    check("temperatures in 20...110 °C", [r.cpuTempC, r.gpuTempC].allSatisfy { $0.map { (20...110).contains($0) } ?? false })
    check("fans reported", !r.fanRPM.isEmpty)
} else {
    check("SMC open", false)
}
let tokenSource = TokenSource(config: .init())
let semaphore = DispatchSemaphore(value: 0)
// Detached: top-level code runs on the main actor, which `semaphore.wait()` blocks.
Task.detached {
    let snapshot = await tokenSource.fetch()
    if let snapshot {
        print("oMLX: \(snapshot.activeRequests) active request(s), \(snapshot.generating.count) generating")
        check("oMLX activity reachable", true)
    } else {
        print("oMLX: unavailable (\(tokenSource.lastError ?? "unknown"))")
        check("oMLX activity reachable (WARN is fine if KonaClaw is not running)", false)
    }
    semaphore.signal()
}
semaphore.wait()
