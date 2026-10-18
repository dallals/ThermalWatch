import AppKit
import Foundation
import ThermalCore
import ThermalSensors

func show(_ v: Double?, _ unit: String, digits: Int = 0) -> String {
    v.map { String(format: "%.\(digits)f%@", $0, unit) } ?? "unavailable"
}

func check(_ label: String, _ ok: Bool) {
    print("  \(ok ? "OK  " : "WARN") \(label)")
}

if CommandLine.arguments.contains("--reclassify-history") {
    reclassifyHistory()
    exit(0)
}

/// Rewrites stored states and events under the current detection rules. The app must not be running,
/// since it writes to the same database.
func reclassifyHistory() {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.sammydallal.thermalwatch").isEmpty {
        print("ThermalWatch is running; quit it first.")
        exit(1)
    }
    do {
        let store = try HistoryStore(path: try HistoryStore.defaultPath())
        let samples = try store.samples(from: 0, to: Date().timeIntervalSince1970 + 1)
        let before = try store.events(from: 0, to: .greatestFiniteMagnitude)
        let r = Reclassify.run(samples, tableMax: PMGR.readTables().maxByCluster)
        let changed = zip(samples.sorted { $0.timestamp < $1.timestamp }, r.samples)
            .filter { $0.state != $1.state || $0.clockLimited != $1.clockLimited }.count
        try store.replaceClassification(samples: r.samples, events: r.events)
        print("\(samples.count) samples, \(changed) reclassified; events \(before.count) -> \(r.events.count)")
        for e in r.events.reversed() {
            let start = Date(timeIntervalSince1970: e.start).formatted(date: .omitted, time: .standard)
            print("  \(start)  \(Int(e.duration))s  pressure \(e.worstPressure)  clocks -\(Int((e.maxClockDrop * 100).rounded()))%")
        }
    } catch {
        print("reclassify failed: \(error)")
        exit(1)
    }
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
