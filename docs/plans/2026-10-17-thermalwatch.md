# ThermalWatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that shows, records and alerts on thermal throttling of the M5 Max 14-inch, with oMLX token speed on the same timeline and a built-in load test.

**Architecture:** One SwiftPM package with four library/executable layers: `ThermalCore` (pure models, rules, SQLite history, the `Monitor` orchestrator), `ThermalSensors` (IOReport, SMC, pmgr tables, thermal-pressure notify, oMLX HTTP), `ThermalLoad` (CPU threads + Metal compute load), and two executables (`ThermalWatchApp` SwiftUI menu-bar app, `thermalwatch-probe` CLI). A `build.sh` wraps the app binary into a signed `.app`.

**Tech Stack:** Swift 6.4 toolchain (language mode 5), SwiftUI, Swift Charts, Observation, Swift Testing, SQLite3 (system), IOKit, Metal, ServiceManagement, UserNotifications. No third-party dependencies.

**Spec:** `docs/specs/2026-10-17-thermalwatch-design.md` (read it before starting any task).

## Global Constraints

- Repo root: `/Users/sammydallal/Desktop/claudeCode/ThermalWatch`. All commands below use absolute paths.
- Native arm64 only: every `swift` command is prefixed with `arch -arm64`. Never Rosetta.
- `swift-tools-version: 6.0`, platforms `.macOS("27.0")`, every target uses `swiftSettings: [.swiftLanguageMode(.v5)]`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`).
- No third-party packages. No `sudo`, no `powermetrics`.
- oMLX is read-only: the app only sends `GET /admin/api/activity`. Never log, store or display an API key; decode only the fields listed in the spec.
- Bundle id `com.sammydallal.thermalwatch`. Sign with the "KonaClaw Dev" identity when `security find-identity -p codesigning` lists it, otherwise ad-hoc (`-`).
- Throttle constants (one place, `Thresholds`): busy `0.60`, busy run `5` s, throttle drop `0.15`, warm drop `0.05`, warm temp `95` °C, max gap between consecutive samples `2` s. Event close-after `10` s. Alerts: heavy = pressure ≥ 2, sustained = clock-limited ≥ `30` s, min interval `600` s. Load test hot limit `105` °C. Retention default `7` days.
- Implementers never run `./build.sh --install` and never touch `~/Applications`; the controller does installs and manual checks.
- Every commit message ends with these two lines (blank line before them):
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01CAkB4LKRVB3HEQACFmxDog
  ```
  Write each commit as `git -C /Users/sammydallal/Desktop/claudeCode/ThermalWatch commit -m "<subject>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01CAkB4LKRVB3HEQACFmxDog"`.

## Probed facts this plan relies on (2026-10-17, this Mac)

- IOReport cluster channels (group "CPU Stats", subgroup "CPU Complex Performance States"): `PCPU` (Super), `MCPU0`, `MCPU1` (Performance). States `DOWN`, `IDLE`, `V<n>P<m>`; `n` indexes the frequency table. Per-core subgroup "CPU Core Performance States": `PCPU0`–`PCPU5`, `MCPU00`–`MCPU05`, `MCPU10`–`MCPU15`.
- GPU: subgroup "GPU Performance States" channel `GPUPH` (`OFF`, `P1`–`P15`); subgroup "CLTM-induced GPU Performance States" channel `GPU_CLTM` (`OFF`, `P1`–`P15`, `NO_CLTM`).
- "Energy Model" channel `GPU Energy`, unit `nJ`. `CPU Energy` reads 0 on M5.
- pmgr tables: `voltage-states5-sram` (Super, kHz), `voltage-states22-sram` (Performance, kHz), `voltage-states9` (GPU, Hz, entry 0 = 0). Entries are 8-byte pairs; first little-endian UInt32 is the frequency.
- SMC (`AppleSMC`, selector 2, 80-byte struct, `data8` 9 = key info, 5 = read, 8 = key at index): `FNum`, `F<n>Ac`, `PHPC` (CPU W), `PSTR` (system W), temps `Tp*`/`Tm*` (CPU), `Tg*` (GPU), type `flt ` little-endian.
- oMLX `GET http://127.0.0.1:8901/admin/api/activity` → `{"active_models": {"total_active_requests": Int, "models": [{"generating": [{"request_id", "generated_tokens", "elapsed_seconds"}]}]}}`, 200 without a key.

## Review Focus

1. **Sleep/wake gaps** (samples jump by minutes): a busy run must not bridge the gap, an open event must close and a new one open, and token rate must not count requests that started before the gap. Tests: Task 4 `gapBreaksBusyRun`, Task 5 `requestStartedBeforeWatchingIsSkipped`, Task 6 `eventSplitsAcrossGap`.
2. **oMLX/KonaClaw not running**: tokens are `nil`, nothing hangs (0.8 s timeout), the 1 Hz loop keeps going. Tests: Task 5 `unreachableServerReturnsNilQuickly`, Task 9 `tickCompletesWhenTokensUnavailable`.
3. **First launch / no history / missing tables**: no false throttle, no division by zero. Tests: Task 2 `emptyTableGivesNoFrequency`, Task 4 `emptyPeaksNeverClockLimited`.
4. **Powered-down or idle clusters** (all `DOWN`, or low clocks at low load): never read as a clock drop. Tests: Task 2 `poweredDownClusterHasNoFrequency`, Task 6 `idleClusterDoesNotCountAsDrop`.
5. **History database unavailable** (disk full, locked): the app keeps sampling, shows the error, and retries the unsaved samples. Test: Task 9 `storeFailureKeepsRunningAndRetries`.

---

### Task 1: Package scaffold and core sample model

**Files:**
- Create: `Package.swift`
- Create: `Sources/ThermalCore/Sample.swift`
- Test: `Tests/ThermalCoreTests/SampleTests.swift`

**Interfaces:**
- Produces: `Cluster` (`.superCores` "super", `.performance` "perf", `.gpu` "gpu", `label`), `ThrottleState` (`.cool` 0, `.warm` 1, `.throttled` 2, `label`), `PressureLevel` (0–4, `label`), `Sample` (fields per spec, `init(timestamp:pressure:)`, `mhz(_:)`, `busy(_:)`).

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let mode5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ThermalWatch",
    platforms: [.macOS("27.0")],
    products: [],
    targets: [
        .target(
            name: "ThermalCore",
            swiftSettings: mode5,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "ThermalCoreTests", dependencies: ["ThermalCore"], swiftSettings: mode5),
    ]
)
```

- [ ] **Step 2: Write the failing test** `Tests/ThermalCoreTests/SampleTests.swift`

```swift
import Foundation
import Testing
@testable import ThermalCore

@Test func sampleAccessorsMapClusters() {
    var s = Sample(timestamp: 10)
    s.superMHz = 4000; s.perfMHz = 3500; s.gpuMHz = 1500
    s.superBusy = 0.9; s.perfBusy = 0.5; s.gpuBusy = 0.1
    #expect(s.mhz(.superCores) == 4000)
    #expect(s.mhz(.performance) == 3500)
    #expect(s.mhz(.gpu) == 1500)
    #expect(s.busy(.superCores) == 0.9)
    #expect(s.busy(.performance) == 0.5)
    #expect(s.busy(.gpu) == 0.1)
}

@Test func sampleDefaultsAreEmpty() {
    let s = Sample(timestamp: 5)
    #expect(s.pressure == nil)
    #expect(s.fanRPM.isEmpty)
    #expect(s.state == .cool)
    #expect(s.clockLimited == false)
}

@Test func sampleRoundTripsThroughJSON() throws {
    var s = Sample(timestamp: 1_700_000_000.5, pressure: 2)
    s.fanRPM = [2400, 2380]
    s.state = .throttled
    s.clockLimited = true
    s.gpuThermalCapped = true
    s.tokensPerSec = 38.5
    let data = try JSONEncoder().encode(s)
    #expect(try JSONDecoder().decode(Sample.self, from: data) == s)
}

@Test func labels() {
    #expect(PressureLevel(rawValue: 0)?.label == "Nominal")
    #expect(PressureLevel(rawValue: 3)?.label == "Trapping")
    #expect(PressureLevel(rawValue: 9) == nil)
    #expect(Cluster.performance.label == "Perf")
    #expect(ThrottleState.throttled.label == "THROTTLED")
    #expect(ThrottleState.warm > ThrottleState.cool)
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: build FAILS (`cannot find 'Sample' in scope`).

- [ ] **Step 4: Implement** `Sources/ThermalCore/Sample.swift`

```swift
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
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git -C /Users/sammydallal/Desktop/claudeCode/ThermalWatch add Package.swift Sources Tests
git -C /Users/sammydallal/Desktop/claudeCode/ThermalWatch commit -m "feat(core): package scaffold and Sample model" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CAkB4LKRVB3HEQACFmxDog"
```

---

### Task 2: Sensor decoding (frequency tables, residency, SMC values, energy)

Pure functions the hardware layer (Task 3) calls. No hardware access here.

**Files:**
- Modify: `Package.swift` (add `ThermalSensors` + its test target)
- Create: `Sources/ThermalSensors/Decoding.swift`
- Test: `Tests/ThermalSensorsTests/DecodingTests.swift`

**Interfaces:**
- Consumes: `Cluster` (Task 1).
- Produces: `StateResidency(name:ticks:)`; `Residency.tableIndex(_:) -> Int?`, `Residency.summarize(_:table:) -> Residency.Summary?` (`activeFraction`, `averageMHz`), `Residency.merge(_:) -> [StateResidency]`, `Residency.thermalCapped(_:) -> Bool`; `FrequencyTable.decode(_:divisor:) -> [Double]`; `SMCValue.decode(type:bytes:) -> Double?`, `SMCValue.fourCC(_:) -> UInt32`, `SMCValue.string(_:) -> String`; `SMCKeys.isCPUDie(_:)`, `SMCKeys.isGPUDie(_:)`, `SMCKeys.hottest(_:where:) -> Double?`; `Energy.watts(value:unit:seconds:) -> Double?`.

- [ ] **Step 1: Add targets to `Package.swift`** — append inside `targets: [ ... ]`:

```swift
        .target(
            name: "ThermalSensors",
            dependencies: ["ThermalCore"],
            swiftSettings: mode5,
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "ThermalSensorsTests", dependencies: ["ThermalSensors"], swiftSettings: mode5),
```

- [ ] **Step 2: Write the failing tests** `Tests/ThermalSensorsTests/DecodingTests.swift`

```swift
import Foundation
import Testing
@testable import ThermalSensors

private func st(_ pairs: [(String, Int64)]) -> [StateResidency] {
    pairs.map { StateResidency(name: $0.0, ticks: $0.1) }
}

@Test func tableIndexParsesStateNames() {
    #expect(Residency.tableIndex("V12P7") == 12)
    #expect(Residency.tableIndex("V0P19") == 0)
    #expect(Residency.tableIndex("P3") == 3)
    #expect(Residency.tableIndex("IDLE") == nil)
    #expect(Residency.tableIndex("DOWN") == nil)
    #expect(Residency.tableIndex("OFF") == nil)
    #expect(Residency.tableIndex("NO_CLTM") == nil)
    #expect(Residency.tableIndex("NON_IDLE") == nil)
}

@Test func summarizeWeightsFrequencyByResidency() throws {
    let s = try #require(Residency.summarize(st([("IDLE", 50), ("V0P2", 25), ("V2P0", 25)]), table: [1000, 2000, 3000]))
    #expect(s.activeFraction == 0.5)
    #expect(s.averageMHz == 2000)
}

@Test func summarizeClampsIndexPastTableEnd() throws {
    let s = try #require(Residency.summarize(st([("P5", 10)]), table: [100, 200]))
    #expect(s.averageMHz == 200)
    #expect(s.activeFraction == 1)
}

@Test func poweredDownClusterHasNoFrequency() throws {
    let s = try #require(Residency.summarize(st([("DOWN", 100), ("IDLE", 0), ("V3P1", 0)]), table: [1000, 2000, 3000, 4000]))
    #expect(s.activeFraction == 0)
    #expect(s.averageMHz == nil)
}

@Test func emptyTableGivesNoFrequency() throws {
    let s = try #require(Residency.summarize(st([("V1P0", 100)]), table: []))
    #expect(s.activeFraction == 1)
    #expect(s.averageMHz == nil)
}

@Test func summarizeNeedsTicks() {
    #expect(Residency.summarize([], table: [1]) == nil)
    #expect(Residency.summarize(st([("IDLE", 0)]), table: [1]) == nil)
}

@Test func mergeSumsTicksByNameKeepingOrder() {
    let merged = Residency.merge([st([("DOWN", 100), ("V1P0", 0)]), st([("DOWN", 0), ("V1P0", 50), ("IDLE", 5)])])
    #expect(merged == st([("DOWN", 100), ("V1P0", 50), ("IDLE", 5)]))
}

@Test func thermalCapDetectsAnyPState() {
    #expect(Residency.thermalCapped(st([("NO_CLTM", 100), ("P1", 0)])) == false)
    #expect(Residency.thermalCapped(st([("NO_CLTM", 90), ("P4", 10)])) == true)
    #expect(Residency.thermalCapped(st([("OFF", 100)])) == false)
}

@Test func frequencyTableDecodesLittleEndianPairs() {
    var data = Data()
    for v: UInt32 in [1_308_000, 900, 4_608_000, 1100] {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(0xFF) // trailing partial entry is ignored
    #expect(FrequencyTable.decode(data, divisor: 1_000) == [1308, 4608])
}

@Test func smcValueDecoding() {
    let bits = Float(54.5).bitPattern
    let flt: [UInt8] = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
    #expect(SMCValue.decode(type: "flt ", bytes: flt) == 54.5)
    #expect(SMCValue.decode(type: "flt ", bytes: [1, 2]) == nil)
    #expect(SMCValue.decode(type: "ui8 ", bytes: [2]) == 2)
    #expect(SMCValue.decode(type: "ui16", bytes: [0x1E, 0x92]) == 7826)
    #expect(SMCValue.decode(type: "ui32", bytes: [0, 0, 0x0F, 0x18]) == 3864)
    #expect(SMCValue.decode(type: "sp78", bytes: [0x28, 0x80]) == 40.5)
    #expect(SMCValue.decode(type: "fpe2", bytes: [0x25, 0x80]) == 2400)
    #expect(SMCValue.decode(type: "ch8*", bytes: [65]) == nil)
}

@Test func fourCCRoundTrip() {
    #expect(SMCValue.fourCC("F0Ac") == 0x4630_4163)
    #expect(SMCValue.string(0x4630_4163) == "F0Ac")
}

@Test func hottestFiltersByPrefixAndRange() {
    let r: [String: Double] = ["Tp00": 54, "Tm01": 61, "Tg0a": 47, "Tp99": 140, "Tf06": 93]
    #expect(SMCKeys.hottest(r, where: SMCKeys.isCPUDie) == 61)
    #expect(SMCKeys.hottest(r, where: SMCKeys.isGPUDie) == 47)
    #expect(SMCKeys.hottest([:], where: SMCKeys.isGPUDie) == nil)
}

@Test func energyToWatts() {
    #expect(Energy.watts(value: 2_000_000_000, unit: "nJ", seconds: 2) == 1.0)
    #expect(Energy.watts(value: 1000, unit: "mJ", seconds: 1) == 1.0)
    #expect(Energy.watts(value: 5, unit: "bogus", seconds: 1) == nil)
    #expect(Energy.watts(value: 5, unit: "mJ", seconds: 0) == nil)
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter ThermalSensorsTests`
Expected: build FAILS (`cannot find 'Residency' in scope`).

- [ ] **Step 4: Implement** `Sources/ThermalSensors/Decoding.swift`

```swift
import Foundation

public struct StateResidency: Equatable, Sendable {
    public let name: String
    public let ticks: Int64
    public init(name: String, ticks: Int64) {
        self.name = name
        self.ticks = ticks
    }
}

public enum Residency {
    public struct Summary: Equatable, Sendable {
        /// Share of all ticks spent in a performance state (not DOWN/IDLE/OFF).
        public var activeFraction: Double
        /// Residency-weighted frequency over performance states; nil if never active or no table.
        public var averageMHz: Double?
    }

    /// "V12P7" -> 12 (CPU), "P3" -> 3 (GPU); DOWN/IDLE/OFF/NO_CLTM/NON_IDLE -> nil.
    public static func tableIndex(_ name: String) -> Int? {
        if name.hasPrefix("V"), let p = name.firstIndex(of: "P") {
            return Int(name[name.index(after: name.startIndex)..<p])
        }
        if name.hasPrefix("P") { return Int(name.dropFirst()) }
        return nil
    }

    public static func summarize(_ states: [StateResidency], table: [Double]) -> Summary? {
        let total = states.reduce(Int64(0)) { $0 + max(0, $1.ticks) }
        guard total > 0 else { return nil }
        var active: Int64 = 0
        var weighted = 0.0
        for s in states {
            guard s.ticks > 0, let idx = tableIndex(s.name) else { continue }
            active += s.ticks
            if !table.isEmpty { weighted += table[min(idx, table.count - 1)] * Double(s.ticks) }
        }
        let average: Double? = (active > 0 && !table.isEmpty) ? weighted / Double(active) : nil
        return Summary(activeFraction: Double(active) / Double(total), averageMHz: average)
    }

    /// Sums ticks per state name across channels (e.g. MCPU0 + MCPU1), keeping first-seen order.
    public static func merge(_ channels: [[StateResidency]]) -> [StateResidency] {
        var order: [String] = []
        var sums: [String: Int64] = [:]
        for channel in channels {
            for s in channel {
                if sums[s.name] == nil { order.append(s.name) }
                sums[s.name, default: 0] += s.ticks
            }
        }
        return order.map { StateResidency(name: $0, ticks: sums[$0] ?? 0) }
    }

    /// GPU_CLTM: any time in a P-state means closed-loop thermal management capped the GPU.
    public static func thermalCapped(_ states: [StateResidency]) -> Bool {
        states.contains { $0.ticks > 0 && $0.name.hasPrefix("P") && tableIndex($0.name) != nil }
    }
}

public enum FrequencyTable {
    /// pmgr `voltage-states*` blobs are 8-byte (frequency, voltage) pairs of little-endian UInt32.
    /// `divisor` converts raw frequency to MHz: 1_000 for kHz tables (M5 CPU), 1_000_000 for Hz (GPU).
    public static func decode(_ data: Data, divisor: Double) -> [Double] {
        var out: [Double] = []
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset + 8 <= raw.count {
                let v = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                out.append(Double(v) / divisor)
                offset += 8
            }
        }
        return out
    }
}

public enum SMCValue {
    public static func decode(type: String, bytes b: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            return b.first.map(Double.init)
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(b.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        default:
            return nil
        }
    }

    public static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    public static func string(_ v: UInt32) -> String {
        let bytes = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum SMCKeys {
    public static func isCPUDie(_ key: String) -> Bool { key.hasPrefix("Tp") || key.hasPrefix("Tm") }
    public static func isGPUDie(_ key: String) -> Bool { key.hasPrefix("Tg") }

    /// Hottest plausible (0–130 °C) reading among keys matching `filter`.
    public static func hottest(_ readings: [String: Double], where filter: (String) -> Bool) -> Double? {
        readings.filter { filter($0.key) && $0.value > 0 && $0.value < 130 }.values.max()
    }
}

public enum Energy {
    public static func watts(value: Int64, unit: String, seconds: Double) -> Double? {
        guard seconds > 0 else { return nil }
        let scale: Double
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "nJ": scale = 1e-9
        case "uJ", "µJ": scale = 1e-6
        case "mJ": scale = 1e-3
        case "J": scale = 1
        default: return nil
        }
        return Double(value) * scale / seconds
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass (Task 1's 4 + 13 new).

- [ ] **Step 6: Commit** — subject `feat(sensors): decoding for residency, frequency tables, SMC values, energy` (add the trailer per Global Constraints).

---
### Task 3: Hardware sources and the probe CLI

Wraps IOReport, pmgr tables, SMC and thermal pressure, and adds `thermalwatch-probe` to check them on this Mac. Hardware calls are not unit-tested; the pure `ClockSource.reading(from:seconds:tables:)` and the SMC struct layout are.

**Files:**
- Modify: `Package.swift` (add the probe executable)
- Create: `Sources/ThermalSensors/IOReport.swift`
- Create: `Sources/ThermalSensors/PMGR.swift`
- Create: `Sources/ThermalSensors/ClockSource.swift`
- Create: `Sources/ThermalSensors/SMC.swift`
- Create: `Sources/ThermalSensors/PressureSource.swift`
- Create: `Sources/ThermalProbe/main.swift`
- Test: `Tests/ThermalSensorsTests/ClockSourceTests.swift`

**Interfaces:**
- Consumes: Task 2 decoding API.
- Produces: `IOReportChannelReading(group:subgroup:channel:unit:states:value:)`; `IOReportSampler(groups:)` with `next(now:) -> (readings:, seconds:)?`; `ClusterTables(superMHz:perfMHz:gpuMHz:)` with `maxByCluster: [Cluster: Double]`; `PMGR.readTables() -> ClusterTables`; `ClockReading` (superMHz, perfMHz, gpuMHz, superBusy, perfBusy, gpuBusy, gpuThermalCapped, gpuWatts — all optional); `ClockSource(tables:)` with `tables`, `available`, `lastReadings`, `read(now:) -> ClockReading?`, `static reading(from:seconds:tables:) -> ClockReading`; `SMCClient()` with `read(_:) -> Double?`, `allKeys() -> [String]`; `SMCReading` (cpuTempC, gpuTempC, fanRPM, cpuWatts, systemWatts); `SMCSource()` (failable) with `read() -> SMCReading`; `PressureSource()` with `read() -> Int?` (0–4 or nil).

- [ ] **Step 1: Add the probe to `Package.swift`** — append inside `targets: [ ... ]`:

```swift
        .executableTarget(name: "ThermalProbe", dependencies: ["ThermalCore", "ThermalSensors"], swiftSettings: mode5),
```

and set `products:` to:

```swift
    products: [
        .executable(name: "thermalwatch-probe", targets: ["ThermalProbe"]),
    ],
```

- [ ] **Step 2: Write the failing tests** `Tests/ThermalSensorsTests/ClockSourceTests.swift`

```swift
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
```

- [ ] **Step 3: Run to verify it fails**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter ClockSourceTests`
Expected: build FAILS (`cannot find 'IOReportChannelReading' in scope`). The probe target also fails to build because `Sources/ThermalProbe` is empty; that is fixed in Step 9.

- [ ] **Step 4: Implement** `Sources/ThermalSensors/IOReport.swift`

```swift
import Foundation

public struct IOReportChannelReading: Equatable, Sendable {
    public let group: String
    public let subgroup: String
    public let channel: String
    public let unit: String
    /// State residencies for state channels (format 2); empty otherwise.
    public let states: [StateResidency]
    /// Integer value for simple channels (format 1); 0 otherwise.
    public let value: Int64

    public init(group: String, subgroup: String, channel: String, unit: String, states: [StateResidency], value: Int64) {
        self.group = group
        self.subgroup = subgroup
        self.channel = channel
        self.unit = unit
        self.states = states
        self.value = value
    }
}

/// dlopen wrapper over the private libIOReport (it lives in the dyld shared cache).
final class IOReportLib {
    typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias ChannelFormat = @convention(c) (CFDictionary) -> UInt8
    typealias StateCount = @convention(c) (CFDictionary) -> Int32
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias StateResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64
    typealias SimpleInteger = @convention(c) (CFDictionary, Int32) -> Int64

    static let shared: IOReportLib? = IOReportLib()

    let copyChannelsInGroup: CopyChannelsInGroup
    let mergeChannels: MergeChannels
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let getGroup: ChannelString
    let getSubGroup: ChannelString
    let getChannelName: ChannelString
    let getUnitLabel: ChannelString
    let getFormat: ChannelFormat
    let stateGetCount: StateCount
    let stateGetName: StateName
    let stateGetResidency: StateResidencyFn
    let simpleGetInteger: SimpleInteger

    private init?() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(h, name).map { unsafeBitCast($0, to: type) }
        }
        guard let a = load("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let b = load("IOReportMergeChannels", MergeChannels.self),
              let c = load("IOReportCreateSubscription", CreateSubscription.self),
              let d = load("IOReportCreateSamples", CreateSamples.self),
              let e = load("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let f = load("IOReportChannelGetGroup", ChannelString.self),
              let g = load("IOReportChannelGetSubGroup", ChannelString.self),
              let i = load("IOReportChannelGetChannelName", ChannelString.self),
              let j = load("IOReportChannelGetUnitLabel", ChannelString.self),
              let k = load("IOReportChannelGetFormat", ChannelFormat.self),
              let l = load("IOReportStateGetCount", StateCount.self),
              let m = load("IOReportStateGetNameForIndex", StateName.self),
              let n = load("IOReportStateGetResidency", StateResidencyFn.self),
              let o = load("IOReportSimpleGetIntegerValue", SimpleInteger.self)
        else { return nil }
        copyChannelsInGroup = a; mergeChannels = b; createSubscription = c
        createSamples = d; createSamplesDelta = e
        getGroup = f; getSubGroup = g; getChannelName = i; getUnitLabel = j; getFormat = k
        stateGetCount = l; stateGetName = m; stateGetResidency = n; simpleGetInteger = o
    }

    func reading(_ channel: NSDictionary) -> IOReportChannelReading {
        let cf = channel as CFDictionary
        func text(_ fn: ChannelString) -> String { fn(cf).map { $0.takeUnretainedValue() as String } ?? "" }
        var states: [StateResidency] = []
        var value: Int64 = 0
        switch getFormat(cf) {
        case 2:
            for idx in 0..<stateGetCount(cf) {
                let name = stateGetName(cf, idx).map { $0.takeUnretainedValue() as String } ?? ""
                states.append(StateResidency(name: name, ticks: stateGetResidency(cf, idx)))
            }
        case 1:
            value = simpleGetInteger(cf, 0)
        default:
            break
        }
        return IOReportChannelReading(
            group: text(getGroup), subgroup: text(getSubGroup), channel: text(getChannelName),
            unit: text(getUnitLabel), states: states, value: value
        )
    }
}

/// Subscribes to IOReport groups once and returns per-interval deltas.
public final class IOReportSampler {
    private let lib: IOReportLib
    private let subscription: OpaquePointer
    private let subscribed: CFMutableDictionary
    private var previous: CFDictionary?
    private var previousTime: Double?

    public init?(groups: [(group: String, subgroup: String?)]) {
        guard let lib = IOReportLib.shared else { return nil }
        var merged: CFMutableDictionary?
        for g in groups {
            guard let chans = lib.copyChannelsInGroup(g.group as CFString, g.subgroup.map { $0 as CFString }, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let m = merged { lib.mergeChannels(m, chans, nil) } else { merged = chans }
        }
        guard let merged else { return nil }
        var out: Unmanaged<CFMutableDictionary>?
        guard let sub = lib.createSubscription(nil, merged, &out, 0, nil), let subscribed = out?.takeRetainedValue() else { return nil }
        self.lib = lib
        self.subscription = sub
        self.subscribed = subscribed
    }

    /// Readings for the interval since the previous call and its length in seconds; nil on the first call.
    public func next(now: Double) -> (readings: [IOReportChannelReading], seconds: Double)? {
        guard let current = lib.createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        defer {
            previous = current
            previousTime = now
        }
        guard let prev = previous, let prevTime = previousTime, now > prevTime,
              let delta = lib.createSamplesDelta(prev, current, nil)?.takeRetainedValue(),
              let channels = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return nil }
        return (channels.map(lib.reading), now - prevTime)
    }
}
```

- [ ] **Step 5: Implement** `Sources/ThermalSensors/PMGR.swift`

```swift
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
```

- [ ] **Step 6: Implement** `Sources/ThermalSensors/ClockSource.swift`

```swift
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
```

- [ ] **Step 7: Implement** `Sources/ThermalSensors/SMC.swift`

```swift
import Foundation
import IOKit

/// Mirrors the kernel's SMCKeyData_t (80 bytes). Field order and padding matter.
struct SMCKeyData {
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    var key: UInt32 = 0
    var vers: (major: UInt8, minor: UInt8, build: UInt8, reserved: UInt8, release: UInt16) = (0, 0, 0, 0, 0)
    var pLimit: (version: UInt16, length: UInt16, cpu: UInt32, gpu: UInt32, mem: UInt32) = (0, 0, 0, 0, 0)
    var keyInfo: (dataSize: UInt32, dataType: UInt32, attributes: UInt8, pad0: UInt8, pad1: UInt8, pad2: UInt8) = (0, 0, 0, 0, 0, 0)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

public final class SMCClient {
    private static let selector: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdKeyAtIndex: UInt8 = 8
    private static let cmdKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.size
        let r = IOConnectCallStructMethod(connection, Self.selector, &input, MemoryLayout<SMCKeyData>.size, &output, &size)
        return (r == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    private func info(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = infoCache[key] { return cached }
        var input = SMCKeyData()
        input.key = key
        input.data8 = Self.cmdKeyInfo
        guard let out = call(&input) else { return nil }
        let value = (size: out.keyInfo.dataSize, type: out.keyInfo.dataType)
        infoCache[key] = value
        return value
    }

    public func read(_ key: String) -> Double? {
        let code = SMCValue.fourCC(key)
        guard let inf = info(code) else { return nil }
        var input = SMCKeyData()
        input.key = code
        input.keyInfo.dataSize = inf.size
        input.data8 = Self.cmdReadKey
        guard let out = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(min(inf.size, 32)))) }
        return SMCValue.decode(type: SMCValue.string(inf.type), bytes: bytes)
    }

    public func allKeys() -> [String] {
        let count = Int(read("#KEY") ?? 0)
        return (0..<count).compactMap { index in
            var input = SMCKeyData()
            input.data8 = Self.cmdKeyAtIndex
            input.data32 = UInt32(index)
            return call(&input).map { SMCValue.string($0.key) }
        }
    }
}

public struct SMCReading: Equatable, Sendable {
    public var cpuTempC: Double?
    public var gpuTempC: Double?
    public var fanRPM: [Double] = []
    public var cpuWatts: Double?
    public var systemWatts: Double?
    public init() {}
}

public final class SMCSource {
    private let client: SMCClient
    private let cpuKeys: [String]
    private let gpuKeys: [String]
    private let fanCount: Int

    public init?(client: SMCClient? = SMCClient()) {
        guard let client else { return nil }
        self.client = client
        let keys = client.allKeys()
        cpuKeys = keys.filter(SMCKeys.isCPUDie)
        gpuKeys = keys.filter(SMCKeys.isGPUDie)
        fanCount = Int(client.read("FNum") ?? 0)
    }

    public var hasTemperatureKeys: Bool { !cpuKeys.isEmpty || !gpuKeys.isEmpty }

    public func read() -> SMCReading {
        func values(_ keys: [String]) -> [String: Double] {
            var out: [String: Double] = [:]
            for k in keys { if let v = client.read(k) { out[k] = v } }
            return out
        }
        var r = SMCReading()
        r.cpuTempC = SMCKeys.hottest(values(cpuKeys), where: SMCKeys.isCPUDie)
        r.gpuTempC = SMCKeys.hottest(values(gpuKeys), where: SMCKeys.isGPUDie)
        r.fanRPM = (0..<fanCount).compactMap { client.read("F\($0)Ac") }
        r.cpuWatts = client.read("PHPC")
        r.systemWatts = client.read("PSTR")
        return r
    }
}
```

- [ ] **Step 8: Implement** `Sources/ThermalSensors/PressureSource.swift`

```swift
import Darwin

/// macOS thermal pressure (0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping), readable without sudo.
public final class PressureSource {
    private var token: Int32 = 0
    private let registered: Bool

    public init() {
        registered = notify_register_check("com.apple.system.thermalpressurelevel", &token) == 0
    }

    deinit { if registered { notify_cancel(token) } }

    public func read() -> Int? {
        guard registered else { return nil }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == 0, state <= 4 else { return nil }
        return Int(state)
    }
}
```

- [ ] **Step 9: Implement the probe** `Sources/ThermalProbe/main.swift`

```swift
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
```

- [ ] **Step 10: Run tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass (5 new in `ClockSourceTests`).

- [ ] **Step 11: Run the probe on this Mac**

Run: `arch -arm64 swift run --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch thermalwatch-probe --states`
Expected: every check line says `OK` (the fan check may say `WARN` only if `FNum` is missing; fans at 0 rpm when idle still count as reported). Super max ≈ 4608 MHz, Perf max ≈ 4380 MHz, GPU max = 1620 MHz. The `--states` output shows per-core channels (`PCPU0`…, `MCPU00`…) with `IDLE`/`V…` state names. Copy the full probe output into the task report. If any check is `WARN`, stop and report it rather than changing thresholds.

- [ ] **Step 12: Commit** — subject `feat(sensors): IOReport, pmgr, SMC and pressure sources plus thermalwatch-probe` (add the trailer).

---
### Task 4: Throttle detector and reference peaks

**Files:**
- Create: `Sources/ThermalCore/ThrottleDetector.swift`
- Test: `Tests/ThermalCoreTests/ThrottleDetectorTests.swift`

**Interfaces:**
- Consumes: `Sample`, `Cluster`, `ThrottleState` (Task 1).
- Produces: `Thresholds` (`busy`, `busySeconds`, `throttleDrop`, `warmDrop`, `warmTempC`, `maxGap`, `static let standard`); `Classification(state:clockLimited:)`; `ThrottleDetector(thresholds:)` with `classify(current:recent:peaks:) -> Classification`; `PeakTracker(tableMax:observed:busyThreshold:)` with `observe(_:)`, `replaceObserved(_:)`, `peaks() -> [Cluster: Double]`.

Rule (spec "Throttle rule"): a cluster is a clock-limit candidate when its busy > 0.60 and `mhz < peak × (1 − 0.15)`; it is clock-limited once its busy run (consecutive samples with busy > 0.60, neighbours ≤ 2 s apart, counted as `current − earliest + 1` seconds) reaches 5 s. `gpuThermalCapped == true` is also clock-limited. Throttled = pressure ≥ 1 or clock-limited. Warm = a die temperature > 95 °C, or a busy cluster with `mhz ≤ peak × (1 − 0.05)` that is not clock-limited. Multiplication form avoids floating-point edge errors. `classify` is called before `observe`, so the current sample never raises its own reference peak.

- [ ] **Step 1: Write the failing tests** `Tests/ThermalCoreTests/ThrottleDetectorTests.swift`

```swift
import Testing
@testable import ThermalCore

private let peaks: [Cluster: Double] = [.performance: 4000]

private func perf(_ t: Double, mhz: Double, busy: Double = 0.9, pressure: Int = 0) -> Sample {
    var s = Sample(timestamp: t, pressure: pressure)
    s.perfMHz = mhz
    s.perfBusy = busy
    return s
}

/// Classifies `samples` in order, feeding each earlier sample as `recent`.
private func run(_ samples: [Sample], peaks: [Cluster: Double] = peaks) -> [Classification] {
    let d = ThrottleDetector()
    var recent: [Sample] = []
    var out: [Classification] = []
    for s in samples {
        out.append(d.classify(current: s, recent: recent, peaks: peaks))
        recent.append(s)
    }
    return out
}

@Test func moderatePressureIsThrottled() {
    let c = run([perf(0, mhz: 4000, busy: 0.1, pressure: 1)])[0]
    #expect(c == Classification(state: .throttled, clockLimited: false))
}

@Test func sleepingPressureIsThrottled() {
    #expect(run([perf(0, mhz: 4000, busy: 0.1, pressure: 4)])[0].state == .throttled)
}

@Test func clockLimitedAfterFiveBusySeconds() {
    let out = run((0..<5).map { perf(Double($0), mhz: 3300) })
    #expect(out[3] == Classification(state: .warm, clockLimited: false))
    #expect(out[4] == Classification(state: .throttled, clockLimited: true))
}

@Test func lowClockWhileNotBusyIsCool() {
    let out = run((0..<6).map { perf(Double($0), mhz: 1500, busy: 0.5) })
    #expect(out.allSatisfy { $0 == Classification(state: .cool, clockLimited: false) })
}

@Test func smallDropIsWarm() {
    let out = run((0..<6).map { perf(Double($0), mhz: 3500) })
    #expect(out[5] == Classification(state: .warm, clockLimited: false))
}

@Test func tinyDropIsCool() {
    #expect(run([perf(0, mhz: 3900)])[0].state == .cool)
}

@Test func hotDieIsWarm() {
    var hot = Sample(timestamp: 0); hot.cpuTempC = 96
    var fine = Sample(timestamp: 0); fine.gpuTempC = 95
    #expect(run([hot])[0].state == .warm)
    #expect(run([fine])[0].state == .cool)
}

@Test func gapBreaksBusyRun() {
    let samples = [0.0, 1, 2, 30, 31, 32].map { perf($0, mhz: 3300) }
    let out = run(samples)
    #expect(out[5].clockLimited == false)
    #expect(out[5].state == .warm)
}

@Test func gpuThermalCapIsClockLimited() {
    var s = Sample(timestamp: 0, pressure: 0)
    s.gpuThermalCapped = true
    #expect(run([s])[0] == Classification(state: .throttled, clockLimited: true))
}

@Test func emptyPeaksNeverClockLimited() {
    let out = run((0..<8).map { perf(Double($0), mhz: 100) }, peaks: [:])
    #expect(out.allSatisfy { $0 == Classification(state: .cool, clockLimited: false) })
}

@Test func peakTrackerPrefersObservedBusyPeak() {
    var p = PeakTracker(tableMax: [.performance: 4380, .gpu: 1620])
    #expect(p.peaks() == [.performance: 4380, .gpu: 1620])
    p.observe(perf(0, mhz: 4100))
    p.observe(perf(1, mhz: 4300, busy: 0.3)) // not busy: ignored
    #expect(p.peaks()[.performance] == 4100)
    #expect(p.peaks()[.gpu] == 1620)
    p.replaceObserved([.gpu: 1500])
    #expect(p.peaks() == [.performance: 4380, .gpu: 1500])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter ThrottleDetectorTests`
Expected: build FAILS (`cannot find 'ThrottleDetector' in scope`).

- [ ] **Step 3: Implement** `Sources/ThermalCore/ThrottleDetector.swift`

```swift
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
        var limited = current.gpuThermalCapped == true
        var warm = false
        for cluster in Cluster.allCases {
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter ThrottleDetectorTests`
Expected: 11 tests pass.

- [ ] **Step 5: Commit** — subject `feat(core): throttle detector and reference peak tracker` (add the trailer).

---
### Task 5: oMLX token speed (activity decoding, rate tracker, env file, HTTP source)

**Files:**
- Create: `Sources/ThermalCore/TokenRate.swift`
- Create: `Sources/ThermalCore/EnvFile.swift`
- Create: `Sources/ThermalSensors/TokenSource.swift`
- Modify: `Sources/ThermalProbe/main.swift` (append an oMLX section)
- Test: `Tests/ThermalCoreTests/TokenRateTests.swift`
- Test: `Tests/ThermalSensorsTests/TokenSourceTests.swift`

**Interfaces:**
- Produces (ThermalCore): `GeneratingRequest(id:tokens:elapsed:)`; `ActivitySnapshot(activeRequests:generating:)` with `static decode(_ data: Data) throws -> ActivitySnapshot`; `TokenRateTracker()` with `mutating update(_ snapshot: ActivitySnapshot?, now: Double) -> Double?`; `EnvFile.value(named:in:) -> String?`.
- Produces (ThermalSensors): `TokenSource(config:session:)`, `TokenSource.Config(baseURL:bearer:)` (Equatable, default `http://127.0.0.1:8901`, no bearer), `fetch() async -> ActivitySnapshot?`, `lastError: String?`.

- [ ] **Step 1: Write the failing core tests** `Tests/ThermalCoreTests/TokenRateTests.swift`

```swift
import Foundation
import Testing
@testable import ThermalCore

private func snap(_ reqs: [(String, Int, Double?)], active: Int? = nil) -> ActivitySnapshot {
    ActivitySnapshot(activeRequests: active ?? reqs.count, generating: reqs.map { GeneratingRequest(id: $0.0, tokens: $0.1, elapsed: $0.2) })
}

@Test func firstPollHasNoRate() {
    var t = TokenRateTracker()
    #expect(t.update(snap([("a", 100, 5)]), now: 0) == nil)
}

@Test func rateFromTokenDeltas() {
    var t = TokenRateTracker()
    _ = t.update(snap([("a", 100, 5)]), now: 0)
    #expect(t.update(snap([("a", 140, 6)]), now: 1) == 40)
    // a new request that started during the interval counts all its tokens
    #expect(t.update(snap([("a", 180, 7), ("b", 10, 0.5)]), now: 2) == 50)
}

@Test func requestStartedBeforeWatchingIsSkipped() {
    var t = TokenRateTracker()
    _ = t.update(snap([("a", 100, 5)]), now: 0)
    #expect(t.update(snap([("a", 130, 6), ("c", 500, 30)]), now: 1) == 30)
}

@Test func idleAndFailuresGiveNil() {
    var t = TokenRateTracker()
    _ = t.update(snap([("a", 100, 5)]), now: 0)
    #expect(t.update(snap([], active: 0), now: 1) == nil)
    #expect(t.update(nil, now: 2) == nil)
    // after a failure the next poll is a fresh baseline
    #expect(t.update(snap([("a", 300, 9)]), now: 3) == nil)
    #expect(t.update(snap([("a", 330, 10)]), now: 3) == nil) // time did not advance
}

@Test func decodesActivityAndIgnoresOtherFields() throws {
    let json = """
    {"active_models": {"total_active_requests": 2, "models": [
      {"id": "qwen", "generating": [{"request_id": "a", "generated_tokens": 120, "elapsed_seconds": 3.5}]},
      {"id": "gemma", "generating": [{"request_id": "b", "generated_tokens": 40, "elapsed_seconds": null}, {"generated_tokens": 5}]}
    ]}, "api_key": "should-not-be-read"}
    """
    let s = try ActivitySnapshot.decode(Data(json.utf8))
    #expect(s.activeRequests == 2)
    #expect(s.generating == [GeneratingRequest(id: "a", tokens: 120, elapsed: 3.5), GeneratingRequest(id: "b", tokens: 40, elapsed: nil)])
}

@Test func decodeRejectsWrongShape() {
    #expect(throws: (any Error).self) { try ActivitySnapshot.decode(Data("{\"detail\":\"Not Found\"}".utf8)) }
    #expect(throws: (any Error).self) { try ActivitySnapshot.decode(Data("nope".utf8)) }
}

@Test func envFileParsing() {
    let text = """
    # comment
    export OMLX_KEY="abc#123"
    OTHER=1
    SPACED = 'quoted value'
    """
    #expect(EnvFile.value(named: "OMLX_KEY", in: text) == "abc#123")
    #expect(EnvFile.value(named: "OTHER", in: text) == "1")
    #expect(EnvFile.value(named: "SPACED", in: text) == "quoted value")
    #expect(EnvFile.value(named: "MISSING", in: text) == nil)
}

@Test func envFileKeepsHashAndLastAssignmentWins() {
    let text = "KEY=first\nKEY=second # still part of the value\n"
    #expect(EnvFile.value(named: "KEY", in: text) == "second # still part of the value")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter TokenRateTests`
Expected: build FAILS (`cannot find 'TokenRateTracker' in scope`).

- [ ] **Step 3: Implement** `Sources/ThermalCore/TokenRate.swift`

```swift
import Foundation

public struct GeneratingRequest: Equatable, Sendable {
    public var id: String
    public var tokens: Int
    public var elapsed: Double?
    public init(id: String, tokens: Int, elapsed: Double?) {
        self.id = id
        self.tokens = tokens
        self.elapsed = elapsed
    }
}

/// The parts of oMLX `/admin/api/activity` the app uses. Nothing else is decoded.
public struct ActivitySnapshot: Equatable, Sendable {
    public var activeRequests: Int
    public var generating: [GeneratingRequest]

    public init(activeRequests: Int, generating: [GeneratingRequest]) {
        self.activeRequests = activeRequests
        self.generating = generating
    }

    public enum DecodeError: Error { case shape }

    public static func decode(_ data: Data) throws -> ActivitySnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["active_models"] as? [String: Any] else { throw DecodeError.shape }
        var generating: [GeneratingRequest] = []
        for model in (models["models"] as? [[String: Any]]) ?? [] {
            for g in (model["generating"] as? [[String: Any]]) ?? [] {
                guard let id = g["request_id"] as? String else { continue }
                generating.append(GeneratingRequest(id: id, tokens: (g["generated_tokens"] as? Int) ?? 0, elapsed: g["elapsed_seconds"] as? Double))
            }
        }
        return ActivitySnapshot(activeRequests: (models["total_active_requests"] as? Int) ?? 0, generating: generating)
    }
}

/// Live generation speed from successive activity polls (spec "Token speed").
public struct TokenRateTracker: Sendable {
    private var lastTokens: [String: Int] = [:]
    private var lastTime: Double?

    public init() {}

    public mutating func update(_ snapshot: ActivitySnapshot?, now: Double) -> Double? {
        guard let snapshot else {
            lastTokens = [:]
            lastTime = nil
            return nil
        }
        let previous = lastTokens
        let previousTime = lastTime
        lastTokens = Dictionary(snapshot.generating.map { ($0.id, $0.tokens) }, uniquingKeysWith: { max($0, $1) })
        lastTime = now
        guard let previousTime, now > previousTime, !snapshot.generating.isEmpty else { return nil }
        let dt = now - previousTime
        var total = 0
        for r in snapshot.generating {
            if let before = previous[r.id] {
                total += max(0, r.tokens - before)
            } else if let elapsed = r.elapsed, elapsed <= dt {
                total += r.tokens
            }
        }
        return Double(total) / dt
    }
}
```

- [ ] **Step 4: Implement** `Sources/ThermalCore/EnvFile.swift`

```swift
import Foundation

/// Reads `KEY=value` lines the way the KonaClaw env file is written. Values are taken whole:
/// a `#` inside a value is part of the value, not a comment. The last assignment wins.
public enum EnvFile {
    public static func value(named name: String, in text: String) -> String? {
        var found: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == name else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            found = value
        }
        return found
    }
}
```

- [ ] **Step 5: Run core tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter TokenRateTests`
Expected: 8 tests pass.

- [ ] **Step 6: Write the failing source tests** `Tests/ThermalSensorsTests/TokenSourceTests.swift`

```swift
import Foundation
import Testing
@testable import ThermalCore
@testable import ThermalSensors

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (code, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

private let body = Data(#"{"active_models": {"total_active_requests": 1, "models": [{"generating": [{"request_id": "a", "generated_tokens": 7, "elapsed_seconds": 1.0}]}]}}"#.utf8)

@Suite(.serialized) struct TokenSourceTests {
    @Test func fetchDecodesActivityWithoutAuthByDefault() async {
        var seenPath: String?
        var seenAuth: String?
        StubProtocol.handler = { req in
            seenPath = req.url?.path
            seenAuth = req.value(forHTTPHeaderField: "Authorization")
            return (200, body)
        }
        let source = TokenSource(config: .init(), session: stubSession())
        let snap = await source.fetch()
        #expect(snap?.activeRequests == 1)
        #expect(snap?.generating.first?.tokens == 7)
        #expect(seenPath == "/admin/api/activity")
        #expect(seenAuth == nil)
        #expect(source.lastError == nil)
    }

    @Test func bearerIsSentButNeverReported() async {
        var seenAuth: String?
        StubProtocol.handler = { req in
            seenAuth = req.value(forHTTPHeaderField: "Authorization")
            return (401, Data("{\"detail\":\"sekrit-key bad\"}".utf8))
        }
        let source = TokenSource(config: .init(bearer: "sekrit-key"), session: stubSession())
        #expect(await source.fetch() == nil)
        #expect(seenAuth == "Bearer sekrit-key")
        #expect(source.lastError == "HTTP 401")
    }

    @Test func badBodyGivesNil() async {
        StubProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        let source = TokenSource(config: .init(), session: stubSession())
        #expect(await source.fetch() == nil)
        #expect(source.lastError == "Unexpected response")
    }

    @Test func unreachableServerReturnsNilQuickly() async {
        let source = TokenSource(config: .init(baseURL: URL(string: "http://127.0.0.1:9")!))
        let start = Date()
        #expect(await source.fetch() == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(source.lastError?.hasPrefix("Unreachable") == true)
    }
}
```

- [ ] **Step 7: Run to verify it fails**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter TokenSourceTests`
Expected: build FAILS (`cannot find 'TokenSource' in scope`).

- [ ] **Step 8: Implement** `Sources/ThermalSensors/TokenSource.swift`

```swift
import Foundation
import ThermalCore

/// Polls oMLX's live activity. Read-only; errors never include the key or the response body.
public final class TokenSource: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var baseURL: URL
        public var bearer: String?
        public init(baseURL: URL = URL(string: "http://127.0.0.1:8901")!, bearer: String? = nil) {
            self.baseURL = baseURL
            self.bearer = bearer
        }
    }

    public let config: Config
    private let session: URLSession
    public private(set) var lastError: String?

    public init(config: Config, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 0.8
            c.timeoutIntervalForResource = 0.8
            self.session = URLSession(configuration: c)
        }
    }

    public func fetch() async -> ActivitySnapshot? {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("admin/api/activity"))
        request.timeoutInterval = 0.8
        if let bearer = config.bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Unexpected response"
                return nil
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return nil
            }
            let snapshot = try ActivitySnapshot.decode(data)
            lastError = nil
            return snapshot
        } catch let error as URLError {
            lastError = "Unreachable (\(error.code.rawValue))"
            return nil
        } catch {
            lastError = "Unexpected response"
            return nil
        }
    }
}
```

- [ ] **Step 9: Append to the probe** `Sources/ThermalProbe/main.swift` (end of file):

```swift
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
```

- [ ] **Step 10: Run all tests and the probe**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass.
Run: `arch -arm64 swift run --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch thermalwatch-probe`
Expected: the last section prints `oMLX: N active request(s)…` with `OK` when KonaClaw is running. Include the output in the report.

- [ ] **Step 11: Commit** — subject `feat: live oMLX token speed from the activity endpoint` (add the trailer).

---
### Task 6: Event, alert and icon rules

Pure rules that turn classified samples into throttle events, alert decisions, alert text and the menu-bar color.

**Files:**
- Create: `Sources/ThermalCore/Events.swift`
- Create: `Sources/ThermalCore/Alerts.swift`
- Create: `Sources/ThermalCore/IconStatus.swift`
- Test: `Tests/ThermalCoreTests/EventsTests.swift`
- Test: `Tests/ThermalCoreTests/AlertsTests.swift`

**Interfaces:**
- Consumes: `Sample`, `Cluster`, `PressureLevel`, `Thresholds` (Tasks 1, 4).
- Produces: `ThrottleEvent(start:end:worstPressure:maxClockDrop:tokensBefore:tokensDuring:)` (Codable, `id` = `start`, `duration = end − start + 1`); `EventBuilder(closeAfter:busyThreshold:)` with `current`, `mutating feed(_:peaks:) -> ThrottleEvent?`, `mutating flush() -> ThrottleEvent?`, `static clockDrop(_:peaks:busyThreshold:) -> Double`; `AlertKind` (`.heavyPressure`, `.sustainedClockLimit`); `AlertPolicy` (`minInterval`, `sustainSeconds`, `heavyEnabled`, `sustainedEnabled`, `mutating evaluate(_:) -> AlertKind?`); `AlertText.title(_:)`, `AlertText.body(kind:sample:peaks:)`; `StatusColor` (`.gray`, `.green`, `.yellow`, `.orange`, `.red`, `static color(pressure:clockLimited:warm:)`); `IconStatus(color:slashed:)` with `static from(_ sample: Sample?)`.

- [ ] **Step 1: Write the failing event tests** `Tests/ThermalCoreTests/EventsTests.swift`

```swift
import Testing
@testable import ThermalCore

private let peaks: [Cluster: Double] = [.performance: 4000, .gpu: 1600]

private func s(_ t: Double, throttled: Bool, pressure: Int = 1, perf: Double? = nil, busy: Double = 0.9, tps: Double? = nil) -> Sample {
    var x = Sample(timestamp: t, pressure: throttled ? pressure : 0)
    x.state = throttled ? .throttled : .cool
    x.perfMHz = perf
    x.perfBusy = perf == nil ? nil : busy
    x.tokensPerSec = tps
    return x
}

@Test func eventClosesTenSecondsAfterLastThrottledSample() throws {
    var b = EventBuilder()
    var closed: [ThrottleEvent] = []
    for t in 0...4 { if let e = b.feed(s(Double(t), throttled: true), peaks: peaks) { closed.append(e) } }
    for t in 5...13 { if let e = b.feed(s(Double(t), throttled: false), peaks: peaks) { closed.append(e) } }
    #expect(closed.isEmpty)
    #expect(b.current?.start == 0)
    let e = try #require(b.feed(s(14, throttled: false), peaks: peaks))
    #expect(e.start == 0)
    #expect(e.end == 4)
    #expect(e.duration == 5)
    #expect(e.worstPressure == 1)
    #expect(b.current == nil)
}

@Test func rethrottleWithinTenSecondsExtendsEvent() {
    var b = EventBuilder()
    _ = b.feed(s(0, throttled: true, pressure: 1), peaks: peaks)
    _ = b.feed(s(5, throttled: false), peaks: peaks)
    _ = b.feed(s(9, throttled: true, pressure: 3), peaks: peaks)
    #expect(b.current?.start == 0)
    #expect(b.current?.end == 9)
    #expect(b.current?.worstPressure == 3)
}

@Test func eventSplitsAcrossGap() throws {
    var b = EventBuilder()
    _ = b.feed(s(0, throttled: true), peaks: peaks)
    let old = try #require(b.feed(s(300, throttled: true), peaks: peaks))
    #expect(old.start == 0)
    #expect(old.end == 0)
    #expect(b.current?.start == 300)
}

@Test func clockDropUsesBusyClustersOnly() {
    #expect(EventBuilder.clockDrop(s(0, throttled: true, perf: 3000), peaks: peaks, busyThreshold: 0.6) == 0.25)
}

@Test func idleClusterDoesNotCountAsDrop() {
    #expect(EventBuilder.clockDrop(s(0, throttled: true, perf: 800, busy: 0.1), peaks: peaks, busyThreshold: 0.6) == 0)
}

@Test func eventTracksTokensBeforeAndDuring() throws {
    var b = EventBuilder()
    _ = b.feed(s(0, throttled: false, tps: 50), peaks: peaks)   // older than 60 s before start: dropped
    _ = b.feed(s(100, throttled: false, tps: 40), peaks: peaks)
    _ = b.feed(s(101, throttled: false, tps: 42), peaks: peaks)
    _ = b.feed(s(102, throttled: true, perf: 3000, tps: 30), peaks: peaks)
    _ = b.feed(s(103, throttled: true, perf: 3200, tps: 28), peaks: peaks)
    let e = try #require(b.flush())
    #expect(e.tokensBefore == 41)
    #expect(e.tokensDuring == 29)
    #expect(e.maxClockDrop == 0.25)
    #expect(b.flush() == nil)
}
```

- [ ] **Step 2: Write the failing alert/icon tests** `Tests/ThermalCoreTests/AlertsTests.swift`

```swift
import Testing
@testable import ThermalCore

private func p(_ t: Double, pressure: Int = 0, limited: Bool = false) -> Sample {
    var s = Sample(timestamp: t, pressure: pressure)
    s.clockLimited = limited
    s.state = (pressure >= 1 || limited) ? .throttled : .cool
    return s
}

@Test func heavyAlertsOnceOnEntry() {
    var a = AlertPolicy()
    #expect(a.evaluate(p(0, pressure: 2)) == .heavyPressure)
    #expect(a.evaluate(p(1, pressure: 3)) == nil)
    #expect(a.evaluate(p(2, pressure: 0)) == nil)
    #expect(a.evaluate(p(300, pressure: 2)) == nil)   // within 10 minutes of the last alert
    #expect(a.evaluate(p(301, pressure: 0)) == nil)
    #expect(a.evaluate(p(700, pressure: 2)) == .heavyPressure)
}

@Test func sustainedAlertAtThirtySeconds() {
    var a = AlertPolicy()
    for t in 0..<29 { #expect(a.evaluate(p(Double(t), pressure: 1, limited: true)) == nil) }
    #expect(a.evaluate(p(29, pressure: 1, limited: true)) == .sustainedClockLimit)
    #expect(a.evaluate(p(30, pressure: 1, limited: true)) == nil)
}

@Test func disabledAlertsNeverFire() {
    var a = AlertPolicy()
    a.heavyEnabled = false
    a.sustainedEnabled = false
    #expect(a.evaluate(p(0, pressure: 2)) == nil)
    for t in 1...40 { #expect(a.evaluate(p(Double(t), limited: true)) == nil) }
}

@Test func alertText() {
    var s = p(0, pressure: 2)
    s.cpuTempC = 98.4
    s.gpuTempC = 80
    #expect(AlertText.title(.heavyPressure) == "Chip is throttling")
    #expect(AlertText.body(kind: .heavyPressure, sample: s, peaks: [:]) == "Thermal pressure is Heavy. CPU 98°C, GPU 80°C.")

    var l = p(0, limited: true)
    l.perfMHz = 3120; l.perfBusy = 0.95
    #expect(AlertText.title(.sustainedClockLimit) == "Clocks held down")
    #expect(AlertText.body(kind: .sustainedClockLimit, sample: l, peaks: [.performance: 4000]) == "Clocks held down for 30 s. Perf at 78% of peak.")

    var g = p(0, limited: true)
    g.gpuThermalCapped = true
    #expect(AlertText.body(kind: .sustainedClockLimit, sample: g, peaks: [:]) == "Clocks held down for 30 s. GPU thermally capped.")
}

@Test func iconColors() {
    #expect(IconStatus.from(nil) == IconStatus(color: .gray, slashed: false))
    #expect(IconStatus.from(p(0)) == IconStatus(color: .green, slashed: false))
    var warm = p(0); warm.state = .warm
    #expect(IconStatus.from(warm) == IconStatus(color: .yellow, slashed: false))
    #expect(IconStatus.from(p(0, pressure: 1)) == IconStatus(color: .yellow, slashed: false))
    #expect(IconStatus.from(p(0, pressure: 2)) == IconStatus(color: .orange, slashed: false))
    #expect(IconStatus.from(p(0, limited: true)) == IconStatus(color: .orange, slashed: true))
    #expect(IconStatus.from(p(0, pressure: 3, limited: true)) == IconStatus(color: .red, slashed: true))
    #expect(IconStatus.from(p(0, pressure: 4)) == IconStatus(color: .red, slashed: false))
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter "EventsTests|AlertsTests"`
Expected: build FAILS (`cannot find 'EventBuilder' in scope`).

- [ ] **Step 4: Implement** `Sources/ThermalCore/Events.swift`

```swift
import Foundation

public struct ThrottleEvent: Codable, Equatable, Sendable, Identifiable {
    public var start: Double
    public var end: Double
    public var worstPressure: Int
    /// Largest fraction below the reference peak among busy clusters (0–1).
    public var maxClockDrop: Double
    public var tokensBefore: Double?
    public var tokensDuring: Double?

    public init(start: Double, end: Double, worstPressure: Int, maxClockDrop: Double, tokensBefore: Double?, tokensDuring: Double?) {
        self.start = start
        self.end = end
        self.worstPressure = worstPressure
        self.maxClockDrop = maxClockDrop
        self.tokensBefore = tokensBefore
        self.tokensDuring = tokensDuring
    }

    public var id: Double { start }
    public var duration: Double { end - start + 1 }
}

/// Groups consecutive throttled samples into events; an event closes after `closeAfter` seconds without throttling.
public struct EventBuilder: Sendable {
    public var closeAfter: Double
    public var busyThreshold: Double
    public private(set) var current: ThrottleEvent?
    private var lastThrottled: Double = 0
    private var before: [TimedValue] = []
    private var during: [Double] = []

    private struct TimedValue: Sendable {
        var t: Double
        var value: Double
    }

    public init(closeAfter: Double = 10, busyThreshold: Double = Thresholds.standard.busy) {
        self.closeAfter = closeAfter
        self.busyThreshold = busyThreshold
    }

    public static func clockDrop(_ s: Sample, peaks: [Cluster: Double], busyThreshold: Double) -> Double {
        var worst = 0.0
        for cluster in Cluster.allCases {
            guard let mhz = s.mhz(cluster), let busy = s.busy(cluster), busy > busyThreshold,
                  let peak = peaks[cluster], peak > 0 else { continue }
            worst = max(worst, 1 - mhz / peak)
        }
        return worst
    }

    /// Feed every classified sample in order, with the peaks used to classify it.
    /// Returns an event when one closes.
    public mutating func feed(_ s: Sample, peaks: [Cluster: Double]) -> ThrottleEvent? {
        var closed: ThrottleEvent?
        if current != nil, s.timestamp - lastThrottled >= closeAfter { closed = finish() }

        if s.state == .throttled {
            let drop = Self.clockDrop(s, peaks: peaks, busyThreshold: busyThreshold)
            if var e = current {
                e.end = s.timestamp
                e.worstPressure = max(e.worstPressure, s.pressure ?? 0)
                e.maxClockDrop = max(e.maxClockDrop, drop)
                current = e
            } else {
                let window = before.filter { $0.t >= s.timestamp - 60 }.map(\.value)
                current = ThrottleEvent(start: s.timestamp, end: s.timestamp, worstPressure: s.pressure ?? 0,
                                        maxClockDrop: drop, tokensBefore: Self.mean(window), tokensDuring: nil)
                during = []
            }
            if let t = s.tokensPerSec { during.append(t) }
            lastThrottled = s.timestamp
        } else if current == nil, let t = s.tokensPerSec {
            before.append(TimedValue(t: s.timestamp, value: t))
        }
        before.removeAll { $0.t < s.timestamp - 60 }
        return closed
    }

    /// Closes the open event, if any (e.g. when the app quits).
    public mutating func flush() -> ThrottleEvent? {
        current == nil ? nil : finish()
    }

    private mutating func finish() -> ThrottleEvent? {
        guard var e = current else { return nil }
        e.tokensDuring = Self.mean(during)
        current = nil
        during = []
        before = []
        return e
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
```

- [ ] **Step 5: Implement** `Sources/ThermalCore/Alerts.swift`

```swift
import Foundation

public enum AlertKind: String, CaseIterable, Sendable {
    case heavyPressure
    case sustainedClockLimit
}

public struct AlertPolicy: Sendable {
    public var minInterval: Double = 600
    public var sustainSeconds: Double = 30
    public var heavyEnabled = true
    public var sustainedEnabled = true
    private var lastAlert: Double?
    private var wasHeavy = false
    private var limitedSince: Double?
    private var sustainedConsumed = false

    public init() {}

    public mutating func evaluate(_ s: Sample) -> AlertKind? {
        let heavy = (s.pressure ?? 0) >= 2
        let enteredHeavy = heavy && !wasHeavy
        wasHeavy = heavy

        if s.clockLimited {
            if limitedSince == nil {
                limitedSince = s.timestamp
                sustainedConsumed = false
            }
        } else {
            limitedSince = nil
            sustainedConsumed = false
        }
        let sustained = limitedSince.map { s.timestamp - $0 + 1 >= sustainSeconds } ?? false

        var kind: AlertKind?
        if enteredHeavy && heavyEnabled {
            kind = .heavyPressure
        } else if sustained && !sustainedConsumed && sustainedEnabled {
            kind = .sustainedClockLimit
        }
        if sustained { sustainedConsumed = true }

        guard let kind else { return nil }
        if let last = lastAlert, s.timestamp - last < minInterval { return nil }
        lastAlert = s.timestamp
        return kind
    }
}

public enum AlertText {
    public static func title(_ kind: AlertKind) -> String {
        switch kind {
        case .heavyPressure: "Chip is throttling"
        case .sustainedClockLimit: "Clocks held down"
        }
    }

    public static func body(kind: AlertKind, sample s: Sample, peaks: [Cluster: Double]) -> String {
        switch kind {
        case .heavyPressure:
            let level = PressureLevel(rawValue: s.pressure ?? 0)?.label ?? "high"
            var temps: [String] = []
            if let t = s.cpuTempC { temps.append("CPU \(Int(t.rounded()))°C") }
            if let t = s.gpuTempC { temps.append("GPU \(Int(t.rounded()))°C") }
            return "Thermal pressure is \(level)." + (temps.isEmpty ? "" : " " + temps.joined(separator: ", ") + ".")
        case .sustainedClockLimit:
            var text = "Clocks held down for 30 s."
            var worst: (Cluster, Double)?
            for c in Cluster.allCases {
                guard let mhz = s.mhz(c), let peak = peaks[c], peak > 0 else { continue }
                let share = mhz / peak
                if worst == nil || share < worst!.1 { worst = (c, share) }
            }
            if let (c, share) = worst, share < 1 {
                text += " \(c.label) at \(Int((share * 100).rounded()))% of peak."
            } else if s.gpuThermalCapped == true {
                text += " GPU thermally capped."
            }
            return text
        }
    }
}
```

- [ ] **Step 6: Implement** `Sources/ThermalCore/IconStatus.swift`

```swift
import Foundation

public enum StatusColor: String, Sendable {
    case gray, green, yellow, orange, red

    /// Spec "Menu-bar icon": red = trapping/sleeping; orange = heavy, or clock-limited at lower pressure;
    /// yellow = moderate pressure or warm; green otherwise.
    public static func color(pressure: Int, clockLimited: Bool, warm: Bool) -> StatusColor {
        if pressure >= 3 { return .red }
        if pressure == 2 || clockLimited { return .orange }
        if pressure == 1 || warm { return .yellow }
        return .green
    }
}

public struct IconStatus: Equatable, Sendable {
    public var color: StatusColor
    public var slashed: Bool

    public init(color: StatusColor, slashed: Bool) {
        self.color = color
        self.slashed = slashed
    }

    public static func from(_ sample: Sample?) -> IconStatus {
        guard let s = sample else { return IconStatus(color: .gray, slashed: false) }
        let color = StatusColor.color(pressure: s.pressure ?? 0, clockLimited: s.clockLimited, warm: s.state == .warm)
        return IconStatus(color: color, slashed: s.clockLimited)
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass (11 new).

- [ ] **Step 8: Commit** — subject `feat(core): throttle events, alert policy and icon status` (add the trailer).

---
### Task 7: History store (SQLite) and load-test result model

**Files:**
- Create: `Sources/ThermalCore/LoadTestModels.swift`
- Create: `Sources/ThermalCore/HistoryStore.swift`
- Test: `Tests/ThermalCoreTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: `Sample`, `ThrottleEvent`, `Cluster` (Tasks 1, 6).
- Produces: `LoadKind` (`.cpu`, `.gpu`, `.both`, `label`); `StopReason` (`.finished`, `.userStopped`, `.tooHot`, `.appQuit`, `label`); `LoadTestResult` (Codable, fields below, memberwise `init`); `StoreError.sqlite(String)`; protocol `HistoryWriting` (`insert(_ samples: [Sample])`, `insert(_ event: ThrottleEvent)`, `maxBusyMHz(since:busyAbove:) -> [Cluster: Double]`, `prune(olderThan:)`, all `throws`); `HistoryStore(path:)` (`@unchecked Sendable`, conforms to `HistoryWriting`) plus `static defaultPath() throws -> String`, `samples(from:to:) -> [Sample]`, `events(from:to:) -> [ThrottleEvent]` (events overlapping the range, newest first), `throttledSeconds(from:to:) -> Double`, `insert(_ result: LoadTestResult) -> Int64`, `loadTests() -> [LoadTestResult]` (newest first, `id` set).

- [ ] **Step 1: Write the failing tests** `Tests/ThermalCoreTests/HistoryStoreTests.swift`

```swift
import Foundation
import Testing
@testable import ThermalCore

private func tempPath() -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("history.sqlite").path
}

private func full(_ t: Double) -> Sample {
    var s = Sample(timestamp: t, pressure: 1)
    s.superMHz = 4500; s.perfMHz = 4200; s.gpuMHz = 1500
    s.superBusy = 0.7; s.perfBusy = 0.65; s.gpuBusy = 0.2
    s.gpuThermalCapped = false
    s.cpuWatts = 25.5; s.gpuWatts = 3.25; s.systemWatts = 38
    s.cpuTempC = 88.5; s.gpuTempC = 70
    s.fanRPM = [2400, 2380.5]
    s.tokensPerSec = 41.5
    s.state = .throttled
    s.clockLimited = true
    return s
}

@Test func samplesRoundTripWithNilsAndOrdering() throws {
    let store = try HistoryStore(path: tempPath())
    let empty = Sample(timestamp: 5)
    try store.insert([full(10), empty, full(20)])
    let back = try store.samples(from: 0, to: 100)
    #expect(back == [empty, full(10), full(20)])
    #expect(try store.samples(from: 10, to: 10) == [full(10)])
}

@Test func reopeningKeepsData() throws {
    let path = tempPath()
    try HistoryStore(path: path).insert([full(1)])
    #expect(try HistoryStore(path: path).samples(from: 0, to: 2).count == 1)
}

@Test func eventsOverlapQueryNewestFirst() throws {
    let store = try HistoryStore(path: tempPath())
    let a = ThrottleEvent(start: 100, end: 110, worstPressure: 1, maxClockDrop: 0.2, tokensBefore: 40, tokensDuring: 30)
    let b = ThrottleEvent(start: 200, end: 205, worstPressure: 2, maxClockDrop: 0, tokensBefore: nil, tokensDuring: nil)
    try store.insert(a)
    try store.insert(b)
    #expect(try store.events(from: 105, to: 300) == [b, a])
    #expect(try store.events(from: 111, to: 199).isEmpty)
}

@Test func pruneRemovesOldSamplesAndEventsButKeepsLoadTests() throws {
    let store = try HistoryStore(path: tempPath())
    try store.insert([full(10), full(1000)])
    try store.insert(ThrottleEvent(start: 5, end: 20, worstPressure: 1, maxClockDrop: 0, tokensBefore: nil, tokensDuring: nil))
    _ = try store.insert(LoadTestResult(id: nil, startedAt: 1, kind: .cpu, plannedSeconds: 300, ranSeconds: 300, secondsToThrottle: nil, steadyDrop: [:], peakCPUTempC: nil, peakGPUTempC: nil, startWatts: nil, endWatts: nil, stopReason: .finished, note: ""))
    try store.prune(olderThan: 500)
    #expect(try store.samples(from: 0, to: 2000).map(\.timestamp) == [1000])
    #expect(try store.events(from: 0, to: 2000).isEmpty)
    #expect(try store.loadTests().count == 1)
}

@Test func maxBusyMHzIgnoresIdleAndOld() throws {
    let store = try HistoryStore(path: tempPath())
    var idle = full(50); idle.perfMHz = 4380; idle.perfBusy = 0.3
    var old = full(1); old.superMHz = 4608
    try store.insert([full(40), idle, old])
    let peaks = try store.maxBusyMHz(since: 10, busyAbove: 0.6)
    #expect(peaks == [.superCores: 4500, .performance: 4200])
}

@Test func throttledSecondsCountsThrottledSamples() throws {
    let store = try HistoryStore(path: tempPath())
    try store.insert([full(1), full(2), Sample(timestamp: 3), full(4)])
    #expect(try store.throttledSeconds(from: 0, to: 3) == 2)
}

@Test func loadTestsRoundTripNewestFirst() throws {
    let store = try HistoryStore(path: tempPath())
    let r1 = LoadTestResult(id: nil, startedAt: 100, kind: .both, plannedSeconds: 300, ranSeconds: 120, secondsToThrottle: 42, steadyDrop: ["perf": 0.18], peakCPUTempC: 104, peakGPUTempC: 88, startWatts: 90, endWatts: 60, stopReason: .userStopped, note: "desk")
    let r2 = LoadTestResult(id: nil, startedAt: 200, kind: .gpu, plannedSeconds: 600, ranSeconds: 600, secondsToThrottle: nil, steadyDrop: [:], peakCPUTempC: nil, peakGPUTempC: 70, startWatts: 30, endWatts: 30, stopReason: .finished, note: "")
    let id1 = try store.insert(r1)
    let id2 = try store.insert(r2)
    let back = try store.loadTests()
    #expect(back.map(\.id) == [id2, id1])
    var expected = r1; expected.id = id1
    #expect(back[1] == expected)
}

@Test func badPathThrows() {
    #expect(throws: StoreError.self) { try HistoryStore(path: "/nonexistent-dir-\(UUID().uuidString)/h.sqlite") }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter HistoryStoreTests`
Expected: build FAILS (`cannot find 'HistoryStore' in scope`).

- [ ] **Step 3: Implement** `Sources/ThermalCore/LoadTestModels.swift`

```swift
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
```

- [ ] **Step 4: Implement** `Sources/ThermalCore/HistoryStore.swift`

```swift
import Foundation
import SQLite3

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case .sqlite(let m): "SQLite: \(m)" }
    }
}

public protocol HistoryWriting: AnyObject {
    func insert(_ samples: [Sample]) throws
    func insert(_ event: ThrottleEvent) throws
    func maxBusyMHz(since: Double, busyAbove: Double) throws -> [Cluster: Double]
    func prune(olderThan cutoff: Double) throws
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Serialized SQLite connection (SQLITE_OPEN_FULLMUTEX), safe to call from any thread.
public final class HistoryStore: HistoryWriting, @unchecked Sendable {
    private var db: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            db = nil
            throw StoreError.sqlite(message)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS samples (
              ts REAL PRIMARY KEY, pressure INTEGER,
              super_mhz REAL, perf_mhz REAL, gpu_mhz REAL,
              super_busy REAL, perf_busy REAL, gpu_busy REAL, gpu_capped INTEGER,
              cpu_w REAL, gpu_w REAL, sys_w REAL, cpu_t REAL, gpu_t REAL,
              fans TEXT NOT NULL, tps REAL, state INTEGER NOT NULL, limited INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS events (
              start REAL PRIMARY KEY, end REAL NOT NULL, worst INTEGER NOT NULL, drop_frac REAL NOT NULL,
              tps_before REAL, tps_during REAL);
            CREATE TABLE IF NOT EXISTS load_tests (
              id INTEGER PRIMARY KEY AUTOINCREMENT, started REAL NOT NULL, json TEXT NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    public static func defaultPath() throws -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThermalWatch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite").path
    }

    // MARK: Samples

    public func insert(_ samples: [Sample]) throws {
        guard !samples.isEmpty else { return }
        try transaction {
            let st = try prepare("INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(st) }
            for s in samples {
                sqlite3_reset(st)
                sqlite3_clear_bindings(st)
                bindDouble(st, 1, s.timestamp)
                bindInt(st, 2, s.pressure)
                bindDouble(st, 3, s.superMHz)
                bindDouble(st, 4, s.perfMHz)
                bindDouble(st, 5, s.gpuMHz)
                bindDouble(st, 6, s.superBusy)
                bindDouble(st, 7, s.perfBusy)
                bindDouble(st, 8, s.gpuBusy)
                bindInt(st, 9, s.gpuThermalCapped.map { $0 ? 1 : 0 })
                bindDouble(st, 10, s.cpuWatts)
                bindDouble(st, 11, s.gpuWatts)
                bindDouble(st, 12, s.systemWatts)
                bindDouble(st, 13, s.cpuTempC)
                bindDouble(st, 14, s.gpuTempC)
                bindText(st, 15, s.fanRPM.map { String($0) }.joined(separator: ","))
                bindDouble(st, 16, s.tokensPerSec)
                bindInt(st, 17, s.state.rawValue)
                bindInt(st, 18, s.clockLimited ? 1 : 0)
                try step(st)
            }
        }
    }

    public func samples(from start: Double, to end: Double) throws -> [Sample] {
        let st = try prepare("SELECT * FROM samples WHERE ts >= ? AND ts <= ? ORDER BY ts")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, start)
        bindDouble(st, 2, end)
        var out: [Sample] = []
        while try stepRow(st) {
            var s = Sample(timestamp: sqlite3_column_double(st, 0), pressure: int(st, 1))
            s.superMHz = double(st, 2)
            s.perfMHz = double(st, 3)
            s.gpuMHz = double(st, 4)
            s.superBusy = double(st, 5)
            s.perfBusy = double(st, 6)
            s.gpuBusy = double(st, 7)
            s.gpuThermalCapped = int(st, 8).map { $0 != 0 }
            s.cpuWatts = double(st, 9)
            s.gpuWatts = double(st, 10)
            s.systemWatts = double(st, 11)
            s.cpuTempC = double(st, 12)
            s.gpuTempC = double(st, 13)
            s.fanRPM = text(st, 14).split(separator: ",").compactMap { Double($0) }
            s.tokensPerSec = double(st, 15)
            s.state = ThrottleState(rawValue: int(st, 16) ?? 0) ?? .cool
            s.clockLimited = (int(st, 17) ?? 0) != 0
            out.append(s)
        }
        return out
    }

    public func throttledSeconds(from start: Double, to end: Double) throws -> Double {
        let st = try prepare("SELECT COUNT(*) FROM samples WHERE ts >= ? AND ts <= ? AND state = 2")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, start)
        bindDouble(st, 2, end)
        return try stepRow(st) ? sqlite3_column_double(st, 0) : 0
    }

    public func maxBusyMHz(since: Double, busyAbove: Double) throws -> [Cluster: Double] {
        let st = try prepare("""
            SELECT MAX(CASE WHEN super_busy > ?2 THEN super_mhz END),
                   MAX(CASE WHEN perf_busy > ?2 THEN perf_mhz END),
                   MAX(CASE WHEN gpu_busy > ?2 THEN gpu_mhz END)
            FROM samples WHERE ts >= ?1
            """)
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, since)
        bindDouble(st, 2, busyAbove)
        var out: [Cluster: Double] = [:]
        if try stepRow(st) {
            if let v = double(st, 0) { out[.superCores] = v }
            if let v = double(st, 1) { out[.performance] = v }
            if let v = double(st, 2) { out[.gpu] = v }
        }
        return out
    }

    // MARK: Events

    public func insert(_ e: ThrottleEvent) throws {
        let st = try prepare("INSERT OR REPLACE INTO events VALUES (?,?,?,?,?,?)")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, e.start)
        bindDouble(st, 2, e.end)
        bindInt(st, 3, e.worstPressure)
        bindDouble(st, 4, e.maxClockDrop)
        bindDouble(st, 5, e.tokensBefore)
        bindDouble(st, 6, e.tokensDuring)
        try step(st)
    }

    public func events(from start: Double, to end: Double) throws -> [ThrottleEvent] {
        let st = try prepare("SELECT * FROM events WHERE end >= ? AND start <= ? ORDER BY start DESC")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, start)
        bindDouble(st, 2, end)
        var out: [ThrottleEvent] = []
        while try stepRow(st) {
            out.append(ThrottleEvent(start: sqlite3_column_double(st, 0), end: sqlite3_column_double(st, 1),
                                     worstPressure: int(st, 2) ?? 0, maxClockDrop: double(st, 3) ?? 0,
                                     tokensBefore: double(st, 4), tokensDuring: double(st, 5)))
        }
        return out
    }

    public func prune(olderThan cutoff: Double) throws {
        try transaction {
            let a = try prepare("DELETE FROM samples WHERE ts < ?")
            defer { sqlite3_finalize(a) }
            bindDouble(a, 1, cutoff)
            try step(a)
            let b = try prepare("DELETE FROM events WHERE end < ?")
            defer { sqlite3_finalize(b) }
            bindDouble(b, 1, cutoff)
            try step(b)
        }
    }

    // MARK: Load tests

    public func insert(_ result: LoadTestResult) throws -> Int64 {
        var copy = result
        copy.id = nil
        let json = String(decoding: try JSONEncoder().encode(copy), as: UTF8.self)
        let st = try prepare("INSERT INTO load_tests (started, json) VALUES (?, ?)")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, result.startedAt)
        bindText(st, 2, json)
        try step(st)
        return sqlite3_last_insert_rowid(db)
    }

    public func loadTests() throws -> [LoadTestResult] {
        let st = try prepare("SELECT id, json FROM load_tests ORDER BY started DESC, id DESC")
        defer { sqlite3_finalize(st) }
        var out: [LoadTestResult] = []
        while try stepRow(st) {
            guard var r = try? JSONDecoder().decode(LoadTestResult.self, from: Data(text(st, 1).utf8)) else { continue }
            r.id = sqlite3_column_int64(st, 0)
            out.append(r)
        }
        return out
    }

    // MARK: SQLite helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw StoreError.sqlite(message)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return st
    }

    private func step(_ st: OpaquePointer) throws {
        let r = sqlite3_step(st)
        guard r == SQLITE_DONE || r == SQLITE_ROW else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    /// True while rows remain.
    private func stepRow(_ st: OpaquePointer) throws -> Bool {
        switch sqlite3_step(st) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindDouble(_ st: OpaquePointer, _ i: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(st, i, v) } else { sqlite3_bind_null(st, i) }
    }

    private func bindInt(_ st: OpaquePointer, _ i: Int32, _ v: Int?) {
        if let v { sqlite3_bind_int64(st, i, Int64(v)) } else { sqlite3_bind_null(st, i) }
    }

    private func bindText(_ st: OpaquePointer, _ i: Int32, _ v: String) {
        sqlite3_bind_text(st, i, v, -1, SQLITE_TRANSIENT)
    }

    private func double(_ st: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i)
    }

    private func int(_ st: OpaquePointer, _ i: Int32) -> Int? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, i))
    }

    private func text(_ st: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass (8 new).

- [ ] **Step 6: Commit** — subject `feat(core): SQLite history store and load-test result model` (add the trailer).

---
### Task 8: Chart data, CSV export and display formatting

**Files:**
- Create: `Sources/ThermalCore/Downsampler.swift`
- Create: `Sources/ThermalCore/CSVExport.swift`
- Create: `Sources/ThermalCore/Format.swift`
- Test: `Tests/ThermalCoreTests/PresentationTests.swift`

**Interfaces:**
- Consumes: `Sample`, `ThrottleState` (Task 1).
- Produces: `SeriesPoint(t:min:max:mean:)` (Identifiable by `t`); `StateBand(start:end:pressure:clockLimited:)` (Identifiable by `start`); `TimeRange` (`.tenMinutes` 600, `.hour` 3600, `.sixHours` 21600, `.day` 86400, `.week` 604800; `label`; `bucketSeconds` 1/1/30/120/600); `Downsampler.series(_:bucket:value:) -> [SeriesPoint]`, `Downsampler.bands(_:maxGap:) -> [StateBand]`; `CSVExport.header`, `CSVExport.csv(_:) -> String`; `Format.dash`, `ghz`, `percent`, `temp`, `watts`, `grouped`, `rpm`, `tokens`, `duration`, `tokenChange(before:during:)`.

- [ ] **Step 1: Write the failing tests** `Tests/ThermalCoreTests/PresentationTests.swift`

```swift
import Testing
@testable import ThermalCore

private func sample(_ t: Double, perf: Double? = nil, state: ThrottleState = .cool, pressure: Int = 0, limited: Bool = false) -> Sample {
    var s = Sample(timestamp: t, pressure: pressure)
    s.perfMHz = perf
    s.state = state
    s.clockLimited = limited
    return s
}

@Test func seriesBucketsMinMaxMean() {
    let samples = [sample(0, perf: 10), sample(1, perf: 30), sample(2, perf: nil), sample(30, perf: 5)]
    let pts = Downsampler.series(samples, bucket: 30) { $0.perfMHz }
    #expect(pts == [SeriesPoint(t: 0, min: 10, max: 30, mean: 20), SeriesPoint(t: 30, min: 5, max: 5, mean: 5)])
    #expect(Downsampler.series(samples, bucket: 0) { $0.perfMHz }.isEmpty)
}

@Test func bandsMergeConsecutiveThrottledSamples() {
    let samples = [
        sample(0, state: .throttled, pressure: 1),
        sample(1, state: .throttled, pressure: 1),
        sample(2, state: .cool),
        sample(3, state: .throttled, pressure: 1),
        sample(4, state: .throttled, pressure: 2),
        sample(10, state: .throttled, pressure: 2),
        sample(11, state: .throttled, pressure: 2, limited: true),
    ]
    #expect(Downsampler.bands(samples) == [
        StateBand(start: 0, end: 2, pressure: 1, clockLimited: false),
        StateBand(start: 3, end: 4, pressure: 1, clockLimited: false),
        StateBand(start: 4, end: 5, pressure: 2, clockLimited: false),
        StateBand(start: 10, end: 11, pressure: 2, clockLimited: false),
        StateBand(start: 11, end: 12, pressure: 2, clockLimited: true),
    ])
}

@Test func timeRangeBuckets() {
    #expect(TimeRange.tenMinutes.bucketSeconds == 1)
    #expect(TimeRange.week.bucketSeconds == 600)
    #expect(TimeRange.day.label == "24 h")
}

@Test func csvRows() {
    var s = Sample(timestamp: 1_700_000_000, pressure: 1)
    s.perfMHz = 4200
    s.perfBusy = 0.6512
    s.gpuThermalCapped = true
    s.fanRPM = [2400, 2380.4]
    s.state = .throttled
    let csv = CSVExport.csv([s, Sample(timestamp: 1_700_000_001)])
    let lines = csv.split(separator: "\n").map(String.init)
    #expect(lines[0] == CSVExport.header)
    #expect(lines[1] == "2023-11-14T22:13:20Z,1,,4200.0,,,0.651,,1,,,,,,2400;2380,,2,0")
    #expect(lines[2] == "2023-11-14T22:13:21Z,,,,,,,,,,,,,,,,0,0")
    #expect(csv.hasSuffix("\n"))
}

@Test func formatting() {
    #expect(Format.ghz(4420) == "4.42 GHz")
    #expect(Format.ghz(nil) == "—")
    #expect(Format.percent(0.913) == "91%")
    #expect(Format.temp(78.4) == "78°")
    #expect(Format.watts(41.6) == "42 W")
    #expect(Format.grouped(999) == "999")
    #expect(Format.grouped(2400) == "2,400")
    #expect(Format.grouped(1_234_567) == "1,234,567")
    #expect(Format.rpm([2400, 2380]) == "2,400 rpm")
    #expect(Format.rpm([]) == "—")
    #expect(Format.tokens(38.2) == "38 tok/s")
    #expect(Format.tokens(nil) == "idle")
    #expect(Format.duration(0) == "0s")
    #expect(Format.duration(45) == "45s")
    #expect(Format.duration(185) == "3m 05s")
    #expect(Format.duration(3720) == "1h 02m")
    #expect(Format.tokenChange(before: 41, during: 29) == "41 → 29 tok/s, −29%")
    #expect(Format.tokenChange(before: 30, during: 33) == "30 → 33 tok/s, +10%")
    #expect(Format.tokenChange(before: nil, during: 29) == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter PresentationTests`
Expected: build FAILS (`cannot find 'Downsampler' in scope`).

- [ ] **Step 3: Implement** `Sources/ThermalCore/Downsampler.swift`

```swift
import Foundation

public struct SeriesPoint: Equatable, Sendable, Identifiable {
    public var t: Double
    public var min: Double
    public var max: Double
    public var mean: Double
    public init(t: Double, min: Double, max: Double, mean: Double) {
        self.t = t
        self.min = min
        self.max = max
        self.mean = mean
    }
    public var id: Double { t }
}

public struct StateBand: Equatable, Sendable, Identifiable {
    public var start: Double
    /// Exclusive end: last sample's timestamp + 1 s.
    public var end: Double
    public var pressure: Int
    public var clockLimited: Bool
    public init(start: Double, end: Double, pressure: Int, clockLimited: Bool) {
        self.start = start
        self.end = end
        self.pressure = pressure
        self.clockLimited = clockLimited
    }
    public var id: Double { start }
}

public enum TimeRange: Double, CaseIterable, Sendable, Identifiable {
    case tenMinutes = 600
    case hour = 3600
    case sixHours = 21_600
    case day = 86_400
    case week = 604_800

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .tenMinutes: "10 min"
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 d"
        }
    }

    /// Ranges over an hour are drawn from buckets (spec "Window").
    public var bucketSeconds: Double {
        switch self {
        case .tenMinutes, .hour: 1
        case .sixHours: 30
        case .day: 120
        case .week: 600
        }
    }
}

public enum Downsampler {
    /// Samples must be sorted by time. Samples where `value` is nil are skipped.
    public static func series(_ samples: [Sample], bucket: Double, value: (Sample) -> Double?) -> [SeriesPoint] {
        guard bucket > 0 else { return [] }
        var out: [SeriesPoint] = []
        var key: Double?
        var values: [Double] = []
        func emit() {
            guard let key, !values.isEmpty else { return }
            out.append(SeriesPoint(t: key, min: values.min()!, max: values.max()!, mean: values.reduce(0, +) / Double(values.count)))
        }
        for s in samples {
            guard let v = value(s) else { continue }
            let k = (s.timestamp / bucket).rounded(.down) * bucket
            if k != key {
                emit()
                key = k
                values = []
            }
            values.append(v)
        }
        emit()
        return out
    }

    /// Throttled stretches, split when pressure or clock-limit changes, a non-throttled sample appears,
    /// or samples are more than `maxGap` seconds apart.
    public static func bands(_ samples: [Sample], maxGap: Double = 2) -> [StateBand] {
        var out: [StateBand] = []
        var open = false
        for s in samples {
            guard s.state == .throttled else {
                open = false
                continue
            }
            let pressure = s.pressure ?? 0
            if open, var last = out.last, last.pressure == pressure, last.clockLimited == s.clockLimited,
               s.timestamp - (last.end - 1) <= maxGap {
                last.end = s.timestamp + 1
                out[out.count - 1] = last
            } else {
                out.append(StateBand(start: s.timestamp, end: s.timestamp + 1, pressure: pressure, clockLimited: s.clockLimited))
            }
            open = true
        }
        return out
    }
}
```

- [ ] **Step 4: Implement** `Sources/ThermalCore/CSVExport.swift`

```swift
import Foundation

public enum CSVExport {
    public static let header = "time,pressure,super_mhz,perf_mhz,gpu_mhz,super_busy,perf_busy,gpu_busy,gpu_thermal_capped,cpu_w,gpu_w,system_w,cpu_temp_c,gpu_temp_c,fan_rpm,tokens_per_sec,state,clock_limited"

    public static func csv(_ samples: [Sample]) -> String {
        let iso = ISO8601DateFormatter()
        func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        func f3(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }
        var lines = [header]
        for s in samples {
            let columns = [
                iso.string(from: Date(timeIntervalSince1970: s.timestamp)),
                s.pressure.map(String.init) ?? "",
                f1(s.superMHz), f1(s.perfMHz), f1(s.gpuMHz),
                f3(s.superBusy), f3(s.perfBusy), f3(s.gpuBusy),
                s.gpuThermalCapped.map { $0 ? "1" : "0" } ?? "",
                f1(s.cpuWatts), f1(s.gpuWatts), f1(s.systemWatts),
                f1(s.cpuTempC), f1(s.gpuTempC),
                s.fanRPM.map { String(Int($0.rounded())) }.joined(separator: ";"),
                f1(s.tokensPerSec),
                String(s.state.rawValue),
                s.clockLimited ? "1" : "0",
            ]
            lines.append(columns.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
```

- [ ] **Step 5: Implement** `Sources/ThermalCore/Format.swift`

```swift
import Foundation

public enum Format {
    public static let dash = "—"

    public static func ghz(_ mhz: Double?) -> String {
        guard let mhz else { return dash }
        return String(format: "%.2f GHz", mhz / 1000)
    }

    public static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return dash }
        return "\(Int((fraction * 100).rounded()))%"
    }

    public static func temp(_ c: Double?) -> String {
        c.map { "\(Int($0.rounded()))°" } ?? dash
    }

    public static func watts(_ w: Double?) -> String {
        w.map { "\(Int($0.rounded())) W" } ?? dash
    }

    /// Thousands separators without depending on the user's locale.
    public static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    public static func rpm(_ fans: [Double]) -> String {
        guard let top = fans.max() else { return dash }
        return "\(grouped(Int(top.rounded()))) rpm"
    }

    public static func tokens(_ tps: Double?) -> String {
        tps.map { "\(Int($0.rounded())) tok/s" } ?? "idle"
    }

    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }

    /// "41 → 29 tok/s, −29%" or nil when either side is missing.
    public static func tokenChange(before: Double?, during: Double?) -> String? {
        guard let before, let during, before > 0 else { return nil }
        let pct = Int(((during - before) / before * 100).rounded())
        let sign = pct < 0 ? "−" : "+"
        return "\(Int(before.rounded())) → \(Int(during.rounded())) tok/s, \(sign)\(abs(pct))%"
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass (5 new).

- [ ] **Step 7: Commit** — subject `feat(core): chart downsampling, CSV export and display formatting` (add the trailer).

---
### Task 9: Monitor (1 Hz loop) and live sensor suite

`Monitor` ties sources, detector, peaks, events, alerts and storage together. It depends only on the `SensorSuite` and `HistoryWriting` protocols, so it is tested with fakes. `LiveSensors` is the real `SensorSuite`.

**Files:**
- Create: `Sources/ThermalCore/Monitor.swift`
- Create: `Sources/ThermalSensors/LiveSensors.swift`
- Test: `Tests/ThermalCoreTests/MonitorTests.swift`

**Interfaces:**
- Consumes: everything in Tasks 1–8 (`ThrottleDetector`, `PeakTracker`, `EventBuilder`, `AlertPolicy`, `HistoryWriting`, `TokenRateTracker`, `ClockSource`, `SMCSource`, `PressureSource`, `TokenSource`).
- Produces: protocol `SensorSuite` (`tableMax`, `unavailable: Set<String>`, `omlxBusy: Bool`, `read(now:) async -> Sample`); `@MainActor @Observable Monitor(sensors:store:detector:now:)` with read-only `latest`, `recent` (last 3600 s), `openEvent`, `currentPeaks`, `unavailable`, `storeError`; settable `retentionDays`, `alertPolicy`; callbacks `onAlert(AlertKind, Sample)`, `onSample(Sample)`, `onEventClosed(ThrottleEvent)`; `tick(now:) async`, `flush(now:)`, `start()`, `stop()`, `shutdown(now:)`; statics `memorySeconds` 3600, `flushInterval` 10, `maintenanceInterval` 3600. `LiveSensors(tokenConfig:)` with `tokenError`, `lastActivity`, `updateTokenConfig(_:)`. Unavailable keys: `"pressure"`, `"clocks"`, `"temps"`, `"fans"`, `"power"`, `"tokens"`.

- [ ] **Step 1: Write the failing tests** `Tests/ThermalCoreTests/MonitorTests.swift`

```swift
import Foundation
import Testing
@testable import ThermalCore

final class FakeSensors: SensorSuite {
    var tableMax: [Cluster: Double] = [.performance: 4000]
    var unavailable: Set<String> = []
    var omlxBusy = false
    var make: (Double) -> Sample = { Sample(timestamp: $0, pressure: 0) }
    func read(now: Double) async -> Sample { make(now) }
}

final class FakeStore: HistoryWriting {
    var samples: [Sample] = []
    var events: [ThrottleEvent] = []
    var failInserts = false
    var observed: [Cluster: Double] = [:]
    var pruneCutoffs: [Double] = []
    func insert(_ s: [Sample]) throws {
        if failInserts { throw StoreError.sqlite("disk full") }
        samples += s
    }
    func insert(_ e: ThrottleEvent) throws {
        if failInserts { throw StoreError.sqlite("disk full") }
        events.append(e)
    }
    func maxBusyMHz(since: Double, busyAbove: Double) throws -> [Cluster: Double] { observed }
    func prune(olderThan cutoff: Double) throws { pruneCutoffs.append(cutoff) }
}

private func busyPerf(_ mhz: Double) -> (Double) -> Sample {
    { t in
        var s = Sample(timestamp: t, pressure: 0)
        s.perfMHz = mhz
        s.perfBusy = 0.9
        return s
    }
}

@MainActor
private func ticks(_ m: Monitor, _ times: ClosedRange<Int>) async {
    for t in times { await m.tick(now: Double(t)) }
}

@Test @MainActor func tickClassifiesAndKeepsLatest() async {
    let sensors = FakeSensors()
    // Cool at first (this becomes the observed peak), then the clock drops 25% under the same load.
    sensors.make = { t in busyPerf(t < 2 ? 4000 : 3000)(t) }
    let m = Monitor(sensors: sensors, store: nil, now: 0)
    await ticks(m, 0...4)
    #expect(m.latest?.state == .throttled)
    #expect(m.latest?.clockLimited == true)
    #expect(m.recent.count == 5)
    #expect(m.currentPeaks[.performance] == 4000)
}

@Test @MainActor func storePeakReplacesTableMax() async {
    let sensors = FakeSensors()
    sensors.make = busyPerf(2700)
    let store = FakeStore()
    store.observed = [.performance: 3000]
    let m = Monitor(sensors: sensors, store: store, now: 0)
    #expect(store.pruneCutoffs == [-7 * 86_400])
    await ticks(m, 0...5)
    #expect(m.latest?.state == .warm)
    #expect(m.latest?.clockLimited == false)
}

@Test @MainActor func recentKeepsOneHour() async {
    let m = Monitor(sensors: FakeSensors(), store: nil, now: 0)
    await m.tick(now: 0)
    await m.tick(now: 3601)
    #expect(m.recent.map(\.timestamp) == [3601])
}

@Test @MainActor func samplesFlushEveryTenSeconds() async {
    let store = FakeStore()
    let m = Monitor(sensors: FakeSensors(), store: store, now: 0)
    await ticks(m, 0...9)
    #expect(store.samples.isEmpty)
    await m.tick(now: 10)
    #expect(store.samples.count == 11)
}

@Test @MainActor func closedEventsArePersistedAndReported() async {
    let sensors = FakeSensors()
    sensors.make = { t in Sample(timestamp: t, pressure: t <= 2 ? 1 : 0) }
    let store = FakeStore()
    let m = Monitor(sensors: sensors, store: store, now: 0)
    var closed: [ThrottleEvent] = []
    m.onEventClosed = { closed.append($0) }
    await ticks(m, 0...11)
    #expect(m.openEvent?.start == 0)
    await m.tick(now: 12)
    #expect(store.events.map(\.start) == [0])
    #expect(closed.map(\.end) == [2])
    #expect(m.openEvent == nil)
}

@Test @MainActor func alertsAndSampleCallbacks() async {
    let sensors = FakeSensors()
    sensors.make = { Sample(timestamp: $0, pressure: 2) }
    let m = Monitor(sensors: sensors, store: nil, now: 0)
    var alerts: [AlertKind] = []
    var seen = 0
    m.onAlert = { kind, _ in alerts.append(kind) }
    m.onSample = { _ in seen += 1 }
    await ticks(m, 0...2)
    #expect(alerts == [.heavyPressure])
    #expect(seen == 3)
}

@Test @MainActor func tickCompletesWhenTokensUnavailable() async {
    let sensors = FakeSensors()
    sensors.unavailable = ["tokens"]
    let m = Monitor(sensors: sensors, store: nil, now: 0)
    await m.tick(now: 0)
    #expect(m.latest?.tokensPerSec == nil)
    #expect(m.unavailable == ["tokens"])
}

@Test @MainActor func storeFailureKeepsRunningAndRetries() async {
    let store = FakeStore()
    store.failInserts = true
    let m = Monitor(sensors: FakeSensors(), store: store, now: 0)
    await ticks(m, 0...10)
    #expect(m.storeError != nil)
    #expect(m.recent.count == 11)
    store.failInserts = false
    await m.tick(now: 20)
    #expect(store.samples.count == 12)
    #expect(m.storeError == nil)
}

@Test @MainActor func shutdownClosesOpenEventAndFlushes() async {
    let sensors = FakeSensors()
    sensors.make = { Sample(timestamp: $0, pressure: 1) }
    let store = FakeStore()
    let m = Monitor(sensors: sensors, store: store, now: 0)
    await ticks(m, 0...3)
    m.shutdown(now: 4)
    #expect(store.events.map(\.end) == [3])
    #expect(store.samples.count == 4)
    #expect(m.openEvent == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter MonitorTests`
Expected: build FAILS (`cannot find type 'SensorSuite' in scope`).

- [ ] **Step 3: Implement** `Sources/ThermalCore/Monitor.swift`

```swift
import Foundation
import Observation

public protocol SensorSuite: AnyObject {
    /// Frequency-table maxima, the fallback reference peaks.
    var tableMax: [Cluster: Double] { get }
    /// Sources that failed on the last read ("pressure", "clocks", "temps", "fans", "power", "tokens").
    var unavailable: Set<String> { get }
    /// True when oMLX reports an active request.
    var omlxBusy: Bool { get }
    func read(now: Double) async -> Sample
}

@MainActor
@Observable
public final class Monitor {
    public static let memorySeconds: Double = 3600
    public static let flushInterval: Double = 10
    public static let maintenanceInterval: Double = 3600

    public private(set) var latest: Sample?
    public private(set) var recent: [Sample] = []
    public private(set) var openEvent: ThrottleEvent?
    public private(set) var currentPeaks: [Cluster: Double] = [:]
    public private(set) var unavailable: Set<String> = []
    public private(set) var storeError: String?
    public var retentionDays: Double = 7
    public var alertPolicy = AlertPolicy()

    @ObservationIgnored public var onAlert: ((AlertKind, Sample) -> Void)?
    @ObservationIgnored public var onSample: ((Sample) -> Void)?
    @ObservationIgnored public var onEventClosed: ((ThrottleEvent) -> Void)?

    @ObservationIgnored private let sensors: SensorSuite
    @ObservationIgnored private let store: HistoryWriting?
    @ObservationIgnored private let detector: ThrottleDetector
    @ObservationIgnored private var peaks: PeakTracker
    @ObservationIgnored private var events = EventBuilder()
    @ObservationIgnored private var pending: [Sample] = []
    @ObservationIgnored private var lastFlush: Double
    @ObservationIgnored private var lastMaintenance: Double
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init(sensors: SensorSuite, store: HistoryWriting?, detector: ThrottleDetector = ThrottleDetector(),
                now: Double = Date().timeIntervalSince1970) {
        self.sensors = sensors
        self.store = store
        self.detector = detector
        self.peaks = PeakTracker(tableMax: sensors.tableMax, busyThreshold: detector.thresholds.busy)
        self.events = EventBuilder(busyThreshold: detector.thresholds.busy)
        self.lastFlush = now
        self.lastMaintenance = now
        maintain(now: now)
        currentPeaks = peaks.peaks()
    }

    public func tick(now: Double) async {
        var s = await sensors.read(now: now)
        s.timestamp = now
        let usedPeaks = peaks.peaks()
        let window = Array(recent.suffix(Int(detector.thresholds.busySeconds) + 5))
        let c = detector.classify(current: s, recent: window, peaks: usedPeaks)
        s.state = c.state
        s.clockLimited = c.clockLimited
        peaks.observe(s)
        currentPeaks = peaks.peaks()

        latest = s
        recent.append(s)
        let cutoff = now - Self.memorySeconds
        if let first = recent.first, first.timestamp < cutoff { recent.removeAll { $0.timestamp < cutoff } }
        unavailable = sensors.unavailable

        if let closed = events.feed(s, peaks: usedPeaks) { save(closed) }
        openEvent = events.current
        if let kind = alertPolicy.evaluate(s) { onAlert?(kind, s) }
        onSample?(s)

        pending.append(s)
        if now - lastFlush >= Self.flushInterval { flush(now: now) }
        if now - lastMaintenance >= Self.maintenanceInterval { maintain(now: now) }
    }

    /// Writes pending samples. On failure they are kept (up to `memorySeconds`) and retried next flush.
    public func flush(now: Double = Date().timeIntervalSince1970) {
        lastFlush = now
        guard let store, !pending.isEmpty else { return }
        do {
            try store.insert(pending)
            pending.removeAll()
            storeError = nil
        } catch {
            storeError = "\(error)"
            let cutoff = now - Self.memorySeconds
            pending.removeAll { $0.timestamp < cutoff }
        }
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let started = Date().timeIntervalSince1970
                await self?.tick(now: started)
                let elapsed = Date().timeIntervalSince1970 - started
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, 1.0 - elapsed) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Stops sampling, closes any open event and writes everything pending (app quit).
    public func shutdown(now: Double = Date().timeIntervalSince1970) {
        stop()
        if let e = events.flush() { save(e) }
        openEvent = nil
        flush(now: now)
    }

    private func save(_ event: ThrottleEvent) {
        onEventClosed?(event)
        guard let store else { return }
        do { try store.insert(event) } catch { storeError = "\(error)" }
    }

    /// Prunes old history and refreshes reference peaks from the last 7 days plus samples still in memory.
    private func maintain(now: Double) {
        lastMaintenance = now
        guard let store else { return }
        do {
            try store.prune(olderThan: now - retentionDays * 86_400)
            peaks.replaceObserved(try store.maxBusyMHz(since: now - 7 * 86_400, busyAbove: detector.thresholds.busy))
            for s in recent { peaks.observe(s) }
        } catch {
            storeError = "\(error)"
        }
    }
}
```

- [ ] **Step 4: Run core tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter MonitorTests`
Expected: 9 tests pass.

- [ ] **Step 5: Implement** `Sources/ThermalSensors/LiveSensors.swift`

```swift
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
```

- [ ] **Step 6: Build and run all tests**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass; `LiveSensors` compiles (it has no unit test; it is exercised by the app in Task 10).

- [ ] **Step 7: Commit** — subject `feat: Monitor sampling loop and live sensor suite` (add the trailer).

---
### Task 10: Menu-bar app, popover, settings and packaging

**Files:**
- Modify: `Package.swift` (add the app executable + product)
- Create: `Resources/Info.plist`
- Create: `build.sh` (executable)
- Create: `Sources/ThermalWatchApp/ThermalWatchApp.swift`
- Create: `Sources/ThermalWatchApp/AppModel.swift`
- Create: `Sources/ThermalWatchApp/AppSettings.swift`
- Create: `Sources/ThermalWatchApp/Colors.swift`
- Create: `Sources/ThermalWatchApp/MenuBarIcon.swift`
- Create: `Sources/ThermalWatchApp/PopoverView.swift`
- Create: `Sources/ThermalWatchApp/SettingsView.swift`

**Interfaces:**
- Consumes: `Monitor`, `HistoryStore`, `LiveSensors`, `TokenSource.Config`, `EnvFile`, `IconStatus`, `StatusColor`, `Format`, `Downsampler`, `PressureLevel`, `Cluster`.
- Produces (app target, used by Tasks 11–13): `AppModel` (`@MainActor @Observable`; `settings`, `sensors`, `store: HistoryStore?`, `storeOpenError`, `monitor`, `todayThrottled`, `todayLongest`, `loginItemError`, `update(_:)`, `refreshToday(now:)`, `shutdown()`, plus `@ObservationIgnored var onShutdown: [() -> Void]` hooks run first in `shutdown()`); `AppSettings` (Codable struct; `load(_:)`, `save(_:)`, `tokenConfig()`); `StatusColor.swiftUIColor` / `.nsColor`; `PopoverView`; `SettingsView`; `MenuBarLabel`.

UI is verified by building and by the controller's manual check; there are no unit tests in this task.

- [ ] **Step 1: Add the app to `Package.swift`** — append to `targets:`

```swift
        .executableTarget(
            name: "ThermalWatchApp",
            dependencies: ["ThermalCore", "ThermalSensors"],
            swiftSettings: mode5
        ),
```

and add to `products:`

```swift
        .executable(name: "ThermalWatch", targets: ["ThermalWatchApp"]),
```

- [ ] **Step 2: Create** `Resources/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.sammydallal.thermalwatch</string>
    <key>CFBundleName</key>
    <string>ThermalWatch</string>
    <key>CFBundleDisplayName</key>
    <string>ThermalWatch</string>
    <key>CFBundleExecutable</key>
    <string>ThermalWatch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: Create** `build.sh` and `chmod +x` it

```bash
#!/bin/bash
# Build ThermalWatch.app into .build/. With --install, copy it to ~/Applications and launch it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

arch -arm64 swift build -c release --package-path "$ROOT" --product ThermalWatch
BIN_DIR="$(arch -arm64 swift build -c release --package-path "$ROOT" --show-bin-path)"

STAGE="$ROOT/.build/ThermalWatch.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BIN_DIR/ThermalWatch" "$STAGE/Contents/MacOS/ThermalWatch"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"

# A stable self-signed identity keeps notification permission across rebuilds.
IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"KonaClaw Dev"'; then
    IDENTITY="KonaClaw Dev"
fi
codesign --force --sign "$IDENTITY" "$STAGE"
echo "[thermalwatch] built $STAGE (signed: $IDENTITY)"

if [[ $INSTALL -eq 1 ]]; then
    if pgrep -x ThermalWatch >/dev/null; then
        osascript -e 'quit app "ThermalWatch"' >/dev/null 2>&1 || true
        sleep 2
    fi
    mkdir -p "$HOME/Applications"
    rsync -a --delete "$STAGE/" "$HOME/Applications/ThermalWatch.app/"
    open "$HOME/Applications/ThermalWatch.app"
    echo "[thermalwatch] installed ~/Applications/ThermalWatch.app"
fi
```

- [ ] **Step 4: Create** `Sources/ThermalWatchApp/AppSettings.swift`

```swift
import Foundation
import ThermalCore
import ThermalSensors

struct AppSettings: Codable, Equatable {
    var launchAtLogin = true
    var showTempInMenuBar = false
    var alertHeavy = true
    var alertSustained = true
    var retentionDays = 7
    var omlxURL = "http://127.0.0.1:8901"
    var keyEnvPath = "~/.konaclaw.env"
    /// Empty = send no key (oMLX on localhost does not need one).
    var keyEnvVar = ""

    static let defaultsKey = "settings.v1"

    static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func tokenConfig() -> TokenSource.Config? {
        guard let url = URL(string: omlxURL), url.scheme != nil, url.host != nil else { return nil }
        var bearer: String?
        if !keyEnvVar.isEmpty,
           let text = try? String(contentsOfFile: (keyEnvPath as NSString).expandingTildeInPath, encoding: .utf8) {
            bearer = EnvFile.value(named: keyEnvVar, in: text)
        }
        return TokenSource.Config(baseURL: url, bearer: bearer)
    }
}
```

- [ ] **Step 5: Create** `Sources/ThermalWatchApp/AppModel.swift`

```swift
import AppKit
import Foundation
import Observation
import ServiceManagement
import ThermalCore
import ThermalSensors

@MainActor
@Observable
final class AppModel {
    private(set) var settings: AppSettings
    let sensors: LiveSensors
    let store: HistoryStore?
    let storeOpenError: String?
    let monitor: Monitor
    private(set) var todayThrottled: Double = 0
    private(set) var todayLongest: Double = 0
    private(set) var loginItemError: String?

    /// Run first by `shutdown()` (e.g. the load test stops its threads).
    @ObservationIgnored var onShutdown: [() -> Void] = []
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    init() {
        let settings = AppSettings.load()
        let sensors = LiveSensors(tokenConfig: settings.tokenConfig())
        var store: HistoryStore?
        var openError: String?
        do {
            store = try HistoryStore(path: try HistoryStore.defaultPath())
        } catch {
            openError = "\(error)"
        }
        self.settings = settings
        self.sensors = sensors
        self.store = store
        self.storeOpenError = openError
        self.monitor = Monitor(sensors: sensors, store: store)

        applySettings()
        monitor.start()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshToday()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    func update(_ new: AppSettings) {
        settings = new
        new.save()
        applySettings()
    }

    func refreshToday(now: Date = Date()) {
        guard let store else { return }
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let end = now.timeIntervalSince1970
        todayThrottled = (try? store.throttledSeconds(from: start, to: end)) ?? 0
        let events = ((try? store.events(from: start, to: end)) ?? []) + [monitor.openEvent].compactMap { $0 }
        todayLongest = events.map(\.duration).max() ?? 0
    }

    func shutdown() {
        onShutdown.forEach { $0() }
        statsTask?.cancel()
        monitor.shutdown()
    }

    private func applySettings() {
        monitor.retentionDays = Double(settings.retentionDays)
        monitor.alertPolicy.heavyEnabled = settings.alertHeavy
        monitor.alertPolicy.sustainedEnabled = settings.alertSustained
        sensors.updateTokenConfig(settings.tokenConfig())
        applyLoginItem()
    }

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            if settings.launchAtLogin, service.status != .enabled { try service.register() }
            if !settings.launchAtLogin, service.status == .enabled { try service.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Launch at login: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 6: Create** `Sources/ThermalWatchApp/Colors.swift`

```swift
import AppKit
import SwiftUI
import ThermalCore

extension StatusColor {
    var nsColor: NSColor {
        switch self {
        case .gray: .systemGray
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .red: .systemRed
        }
    }

    var swiftUIColor: Color { Color(nsColor: nsColor) }
}
```

- [ ] **Step 7: Create** `Sources/ThermalWatchApp/MenuBarIcon.swift`

```swift
import AppKit
import SwiftUI
import ThermalCore

enum MenuBarIcon {
    /// Chip symbol in the menu bar's text color, a status dot, and a slash when clocks are held down.
    /// Drawn lazily so `labelColor` resolves against the current menu bar appearance.
    static func image(_ status: IconStatus) -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 16), flipped: false) { _ in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            if let chip = NSImage(systemSymbolName: "cpu", accessibilityDescription: "ThermalWatch")?.withSymbolConfiguration(config) {
                chip.draw(in: NSRect(x: 0, y: 1, width: 15, height: 14))
            }
            status.color.nsColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 0, width: 8, height: 8)).fill()
            if status.slashed {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 11, y: 0))
                slash.line(to: NSPoint(x: 21, y: 10))
                slash.lineWidth = 1.5
                NSColor.labelColor.setStroke()
                slash.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let sample = model.monitor.latest
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(IconStatus.from(sample)))
            if model.settings.showTempInMenuBar, let t = sample?.cpuTempC {
                Text(Format.temp(t))
            }
        }
    }
}
```

- [ ] **Step 8: Create** `Sources/ThermalWatchApp/PopoverView.swift`

```swift
import AppKit
import Charts
import SwiftUI
import ThermalCore

struct PopoverView: View {
    let model: AppModel

    var body: some View {
        let sample = model.monitor.latest
        let peaks = model.monitor.currentPeaks
        let status = IconStatus.from(sample)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(status.color.swiftUIColor).frame(width: 10, height: 10)
                Text(sample?.state.label ?? "STARTING").font(.headline)
                Spacer()
                Text("Pressure: \(sample?.pressure.flatMap { PressureLevel(rawValue: $0)?.label } ?? Format.dash)")
                    .foregroundStyle(.secondary)
            }
            ForEach(Cluster.allCases, id: \.self) { cluster in
                ClusterRow(label: cluster.label, mhz: sample?.mhz(cluster), peak: peaks[cluster])
            }
            Text("CPU \(Format.temp(sample?.cpuTempC))  GPU \(Format.temp(sample?.gpuTempC))  Fans \(Format.rpm(sample?.fanRPM ?? []))  \(Format.watts(sample?.systemWatts))")
                .font(.callout.monospacedDigit())
            Text("oMLX  \(Format.tokens(sample?.tokensPerSec))").font(.callout.monospacedDigit())
            Sparkline(samples: Array(model.monitor.recent.suffix(600)), peak: peaks[.performance])
            Text("Throttled \(Format.duration(model.todayThrottled)) today · longest \(Format.duration(model.todayLongest))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = model.monitor.storeError ?? model.storeOpenError {
                Text("History not saving: \(error)").font(.caption).foregroundStyle(.red)
            }
            if !model.monitor.unavailable.subtracting(["tokens"]).isEmpty {
                Text("Unavailable: \(model.monitor.unavailable.sorted().joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                SettingsLink { Text("Settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 330)
    }
}

private struct ClusterRow: View {
    let label: String
    let mhz: Double?
    let peak: Double?

    var body: some View {
        let share = (mhz != nil && (peak ?? 0) > 0) ? min(1, mhz! / peak!) : nil
        HStack {
            Text(label).frame(width: 44, alignment: .leading)
            Text(Format.ghz(mhz)).frame(width: 76, alignment: .trailing).monospacedDigit()
            ProgressView(value: share ?? 0).frame(width: 110)
            Text(share.map { "\(Format.percent($0)) of max" } ?? Format.dash)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Last 10 minutes: Perf clock as % of its reference peak, with throttled stretches shaded.
private struct Sparkline: View {
    let samples: [Sample]
    let peak: Double?

    var body: some View {
        let bands = Downsampler.bands(samples)
        Chart {
            ForEach(bands) { band in
                RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end))
                    .foregroundStyle(StatusColor.color(pressure: band.pressure, clockLimited: band.clockLimited, warm: false).swiftUIColor.opacity(0.25))
            }
            if let peak, peak > 0 {
                ForEach(samples, id: \.timestamp) { s in
                    if let mhz = s.perfMHz {
                        LineMark(x: .value("Time", s.timestamp), y: .value("% of peak", mhz / peak * 100))
                    }
                }
            }
        }
        .chartYScale(domain: 0...110)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 44)
    }
}
```

- [ ] **Step 9: Create** `Sources/ThermalWatchApp/SettingsView.swift`

```swift
import SwiftUI
import ThermalCore

struct SettingsView: View {
    let model: AppModel
    @State private var draft = AppSettings()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $draft.launchAtLogin)
                Toggle("Show CPU temperature in the menu bar", isOn: $draft.showTempInMenuBar)
                Stepper("Keep history for \(draft.retentionDays) days", value: $draft.retentionDays, in: 1...30)
            }
            Section("Alerts") {
                Toggle("Thermal pressure reaches Heavy", isOn: $draft.alertHeavy)
                Toggle("Clocks held down for 30 seconds", isOn: $draft.alertSustained)
            }
            Section("oMLX token speed") {
                TextField("Server URL", text: $draft.omlxURL)
                TextField("Key file", text: $draft.keyEnvPath)
                TextField("Key variable (leave empty for no key)", text: $draft.keyEnvVar)
                if let error = model.sensors.tokenError {
                    Text("Last error: \(error)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.loginItemError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Save") { model.update(draft) }
                    .disabled(draft == model.settings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { draft = model.settings }
    }
}
```

- [ ] **Step 10: Create** `Sources/ThermalWatchApp/ThermalWatchApp.swift`

```swift
import SwiftUI

@main
struct ThermalWatchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
```

- [ ] **Step 11: Build, test and package (no install)**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass.
Run: `/Users/sammydallal/Desktop/claudeCode/ThermalWatch/build.sh`
Expected: ends with `[thermalwatch] built …/.build/ThermalWatch.app (signed: KonaClaw Dev)`.
Run: `codesign -dv /Users/sammydallal/Desktop/claudeCode/ThermalWatch/.build/ThermalWatch.app 2>&1 | grep -E "Identifier|Authority"`
Expected: `Identifier=com.sammydallal.thermalwatch` and `Authority=KonaClaw Dev`.

- [ ] **Step 12: Commit** — subject `feat(app): menu-bar icon, popover, settings and app packaging` (add the trailer).

- [ ] **Step 13 (controller, manual):** `./build.sh --install`. Check: the chip icon with a green dot appears in the menu bar (if the dot renders monochrome, report it; do not change the design); the popover shows live clocks for Super/Perf/GPU, temperatures, fans, power and oMLX speed; Settings opens and saves; `~/Library/Application Support/ThermalWatch/history.sqlite` grows.

---
### Task 11: History window (charts, events list, CSV export)

Rulings carried from the spec for Swift Charts limits: Swift Charts has no second y-axis, so fan RPM is its own compact chart directly under temperatures; it has no hatching, so clock-limited stretches are shown in a dedicated orange "Clocks held down" lane above the charts, in addition to the pressure-colored bands behind every chart.

**Files:**
- Create: `Sources/ThermalWatchApp/ChartBuilder.swift`
- Create: `Sources/ThermalWatchApp/HistoryCharts.swift`
- Create: `Sources/ThermalWatchApp/WindowData.swift`
- Create: `Sources/ThermalWatchApp/EventsList.swift`
- Create: `Sources/ThermalWatchApp/MainWindowView.swift`
- Modify: `Sources/ThermalWatchApp/ThermalWatchApp.swift` (add the window scene)
- Modify: `Sources/ThermalWatchApp/PopoverView.swift` (add "Open window")

**Interfaces:**
- Consumes: `AppModel` (Task 10), `Downsampler`, `SeriesPoint`, `StateBand`, `TimeRange`, `CSVExport`, `Format`, `ThrottleEvent`, `HistoryStore.samples/events`, `Monitor.recent/openEvent/currentPeaks/memorySeconds`.
- Produces: window scene id `"main"`; `ChartSeries`, `ChartBuilder.build(_:bucket:peaks:) -> ChartBuilder.Built`, `MetricChart`, `ClockLane`, `TimeAxis` (reused by Task 13).

- [ ] **Step 1: Create** `Sources/ThermalWatchApp/ChartBuilder.swift`

```swift
import SwiftUI
import ThermalCore

struct ChartSeries: Identifiable {
    let name: String
    let color: Color
    let points: [SeriesPoint]
    var id: String { name }
}

enum ChartBuilder {
    struct Built {
        var clocks: [ChartSeries]
        var temps: [ChartSeries]
        var fans: [ChartSeries]
        var power: [ChartSeries]
        var tokens: [ChartSeries]
        var bands: [StateBand]
        static let empty = Built(clocks: [], temps: [], fans: [], power: [], tokens: [], bands: [])
    }

    /// `samples` sorted by time. Clocks are drawn as % of each cluster's reference peak.
    static func build(_ samples: [Sample], bucket: Double, peaks: [Cluster: Double]) -> Built {
        func percent(_ cluster: Cluster) -> (Sample) -> Double? {
            { s in
                guard let mhz = s.mhz(cluster), let peak = peaks[cluster], peak > 0 else { return nil }
                return mhz / peak * 100
            }
        }
        func series(_ name: String, _ color: Color, _ value: (Sample) -> Double?) -> ChartSeries {
            ChartSeries(name: name, color: color, points: Downsampler.series(samples, bucket: bucket, value: value))
        }
        return Built(
            clocks: [series("Super", .purple, percent(.superCores)), series("Perf", .blue, percent(.performance)), series("GPU", .teal, percent(.gpu))],
            temps: [series("CPU", .red, { $0.cpuTempC }), series("GPU", .orange, { $0.gpuTempC })],
            fans: [series("Fans", .gray, { $0.fanRPM.max() })],
            power: [series("CPU", .red, { $0.cpuWatts }), series("GPU", .orange, { $0.gpuWatts }), series("System", .gray, { $0.systemWatts })],
            tokens: [series("oMLX", .green, { $0.tokensPerSec })],
            bands: Downsampler.bands(samples)
        )
    }
}
```

- [ ] **Step 2: Create** `Sources/ThermalWatchApp/HistoryCharts.swift`

```swift
import Charts
import SwiftUI
import ThermalCore

enum TimeAxis {
    @AxisContentBuilder
    static func marks() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let t = value.as(Double.self) {
                    Text(Date(timeIntervalSince1970: t), format: .dateTime.hour().minute())
                }
            }
        }
    }
}

struct MetricChart: View {
    let title: String
    let unit: String
    let series: [ChartSeries]
    let bands: [StateBand]
    let domain: ClosedRange<Double>
    var height: CGFloat = 120
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold))
                ForEach(series) { s in
                    Label(s.name, systemImage: "circle.fill").font(.caption).foregroundStyle(s.color)
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Chart {
                ForEach(bands) { band in
                    RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end))
                        .foregroundStyle(StatusColor.color(pressure: band.pressure, clockLimited: band.clockLimited, warm: false).swiftUIColor.opacity(0.18))
                }
                ForEach(series) { s in
                    ForEach(s.points) { p in
                        if p.max > p.min {
                            RuleMark(x: .value("Time", p.t), yStart: .value(unit, p.min), yEnd: .value(unit, p.max))
                                .foregroundStyle(s.color.opacity(0.25))
                        }
                        LineMark(x: .value("Time", p.t), y: .value(unit, p.mean), series: .value("Series", s.name))
                            .foregroundStyle(s.color)
                    }
                }
            }
            .chartXScale(domain: domain)
            .chartXAxis { TimeAxis.marks() }
            .chartLegend(.hidden)
            .frame(height: height)
        }
    }
}

/// Orange marks wherever clocks were held down (the spec's "hatched" stretches).
struct ClockLane: View {
    let bands: [StateBand]
    let domain: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Clocks held down").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(bands.filter(\.clockLimited)) { band in
                    RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end),
                                  yStart: .value("y", 0), yEnd: .value("y", 1))
                        .foregroundStyle(.orange)
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 10)
        }
    }
}
```

- [ ] **Step 3: Create** `Sources/ThermalWatchApp/WindowData.swift`

```swift
import Foundation
import Observation
import ThermalCore

@MainActor
@Observable
final class WindowData {
    var range: TimeRange = .tenMinutes
    /// Seconds back from now that the right edge of the charts shows (0 = live).
    var endOffset: Double = 0
    private(set) var samples: [Sample] = []
    private(set) var events: [ThrottleEvent] = []
    private(set) var built = ChartBuilder.Built.empty
    private(set) var end: Double = Date().timeIntervalSince1970

    var domain: ClosedRange<Double> { (end - range.rawValue)...end }

    func reload(model: AppModel) async {
        let now = Date().timeIntervalSince1970
        let end = now - endOffset
        let start = end - range.rawValue
        let bucket = range.bucketSeconds
        let peaks = model.monitor.currentPeaks
        let live: [Sample]? = (endOffset == 0 && range.rawValue <= Monitor.memorySeconds)
            ? model.monitor.recent.filter { $0.timestamp >= start }
            : nil
        let store = model.store
        let openEvent = model.monitor.openEvent

        let result = await Task.detached(priority: .userInitiated) { () -> ([Sample], [ThrottleEvent], ChartBuilder.Built) in
            let samples = live ?? ((try? store?.samples(from: start, to: end)) ?? [])
            var events = (try? store?.events(from: start, to: end)) ?? []
            if let openEvent, openEvent.end >= start { events.insert(openEvent, at: 0) }
            return (samples, events, ChartBuilder.build(samples, bucket: bucket, peaks: peaks))
        }.value

        samples = result.0
        events = result.1
        built = result.2
        self.end = end
    }

    /// Moves the charts so `event` sits in the middle of the current range.
    func center(on event: ThrottleEvent, now: Double = Date().timeIntervalSince1970) {
        let middle = (event.start + event.end) / 2
        endOffset = max(0, now - (middle + range.rawValue / 2))
    }
}
```

- [ ] **Step 4: Create** `Sources/ThermalWatchApp/EventsList.swift`

```swift
import SwiftUI
import ThermalCore

struct EventsList: View {
    let events: [ThrottleEvent]
    let onSelect: (ThrottleEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Throttle events").font(.headline)
            if events.isEmpty {
                Text("None in this range").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(events) { event in
                    Button { onSelect(event) } label: { EventRow(event: event) }
                        .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct EventRow: View {
    let event: ThrottleEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(StatusColor.color(pressure: event.worstPressure, clockLimited: event.maxClockDrop > 0, warm: false).swiftUIColor)
                    .frame(width: 8, height: 8)
                Text(Date(timeIntervalSince1970: event.start), format: .dateTime.month().day().hour().minute().second())
                Spacer()
                Text(Format.duration(event.duration)).monospacedDigit()
            }
            Text("\(PressureLevel(rawValue: event.worstPressure)?.label ?? Format.dash) · clocks −\(Format.percent(event.maxClockDrop))")
                .font(.caption).foregroundStyle(.secondary)
            if let change = Format.tokenChange(before: event.tokensBefore, during: event.tokensDuring) {
                Text(change).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 5: Create** `Sources/ThermalWatchApp/MainWindowView.swift`

```swift
import AppKit
import SwiftUI
import ThermalCore
import UniformTypeIdentifiers

struct MainWindowView: View {
    let model: AppModel
    @State private var data = WindowData()

    var body: some View {
        let built = data.built
        let domain = data.domain
        let unavailable = model.monitor.unavailable
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Range", selection: $data.range) {
                    ForEach(TimeRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
                Spacer()
                Button("Export CSV…", action: exportCSV).disabled(data.samples.isEmpty)
            }
            HStack {
                Text("Back in time").font(.caption)
                Slider(value: $data.endOffset, in: 0...max(1, maxOffset))
                Text(data.endOffset < 1 ? "Live" : "−" + Format.duration(data.endOffset))
                    .font(.caption.monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
            }
            if let error = model.monitor.storeError ?? model.storeOpenError {
                Text("History not saving: \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ClockLane(bands: built.bands, domain: domain)
                        MetricChart(title: "Clocks", unit: "% of peak", series: built.clocks, bands: built.bands, domain: domain,
                                    note: unavailable.contains("clocks") ? "Clock data unavailable" : "% of reference peak")
                        MetricChart(title: "Temperatures", unit: "°C", series: built.temps, bands: built.bands, domain: domain,
                                    note: unavailable.contains("temps") ? "Temperature data unavailable" : nil)
                        MetricChart(title: "Fans", unit: "rpm", series: built.fans, bands: built.bands, domain: domain, height: 60,
                                    note: unavailable.contains("fans") ? "Fan data unavailable" : nil)
                        MetricChart(title: "Power", unit: "W", series: built.power, bands: built.bands, domain: domain,
                                    note: unavailable.contains("power") ? "Power data unavailable" : nil)
                        MetricChart(title: "oMLX tokens/sec", unit: "tok/s", series: built.tokens, bands: built.bands, domain: domain,
                                    note: unavailable.contains("tokens") ? "oMLX not reachable" : nil)
                    }
                    .padding(.trailing, 6)
                }
                EventsList(events: data.events) { data.center(on: $0) }
                    .frame(width: 300)
            }
        }
        .padding(14)
        .frame(minWidth: 1000, minHeight: 760)
        .task(id: "\(data.range.rawValue)-\(Int(data.endOffset))") {
            await data.reload(model: model)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if data.endOffset < 1 { await data.reload(model: model) }
            }
        }
    }

    private var maxOffset: Double {
        Double(model.settings.retentionDays) * 86_400 - data.range.rawValue
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "thermalwatch-\(Int(data.end)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? CSVExport.csv(data.samples).write(to: url, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 6: Add the window scene** — in `ThermalWatchApp.swift`, insert between the `MenuBarExtra` block and `Settings`:

```swift
        Window("ThermalWatch", id: "main") {
            MainWindowView(model: model)
        }
```

- [ ] **Step 7: Add "Open window" to the popover** — in `PopoverView.swift`, add `@Environment(\.openWindow) private var openWindow` as the first property of `PopoverView`, and replace the bottom `HStack { SettingsLink … }` with:

```swift
            HStack {
                Button("Open window") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                SettingsLink { Text("Settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
```

- [ ] **Step 8: Build, test and package**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass.
Run: `/Users/sammydallal/Desktop/claudeCode/ThermalWatch/build.sh`
Expected: builds and signs without errors.

- [ ] **Step 9: Commit** — subject `feat(app): history window with charts, throttle events and CSV export` (add the trailer).

- [ ] **Step 10 (controller, manual):** `./build.sh --install`, open the window from the popover. Check: all charts move live at "10 min"; switching to "24 h" and dragging "Back in time" loads stored history without freezing the UI; Export CSV writes a file whose header matches `CSVExport.header`.

---
### Task 12: Throttle notifications

**Files:**
- Create: `Sources/ThermalWatchApp/Notifier.swift`
- Modify: `Sources/ThermalWatchApp/AppModel.swift` (own a `Notifier`, wire `monitor.onAlert`)
- Modify: `Sources/ThermalWatchApp/SettingsView.swift` (add "Send test notification")

**Interfaces:**
- Consumes: `AlertKind`, `AlertText`, `Sample`, `Monitor.onAlert`, `Monitor.currentPeaks` (Tasks 6, 9).
- Produces: `Notifier` (`requestAuthorization() async`, `post(_:sample:peaks:)`, `postTest()`, `authorized`); `AppModel.notifier`.

The rate limit and on/off switches live in `AlertPolicy` (tested in Task 6); this task only delivers.

- [ ] **Step 1: Create** `Sources/ThermalWatchApp/Notifier.swift`

```swift
import Foundation
import ThermalCore
import UserNotifications

@MainActor
final class Notifier {
    private(set) var authorized = false

    func requestAuthorization() async {
        authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ kind: AlertKind, sample: Sample, peaks: [Cluster: Double]) {
        deliver(id: "\(kind.rawValue)-\(Int(sample.timestamp))", title: AlertText.title(kind),
                body: AlertText.body(kind: kind, sample: sample, peaks: peaks))
    }

    func postTest() {
        deliver(id: "test-\(Int(Date().timeIntervalSince1970))", title: "ThermalWatch", body: "Notifications are working.")
    }

    private func deliver(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
```

- [ ] **Step 2: Wire it in `AppModel.swift`** — add the property next to `monitor`:

```swift
    let notifier = Notifier()
```

and at the end of `init()` (after the `terminateObserver` assignment) add:

```swift
        monitor.onAlert = { [weak self] kind, sample in
            guard let self else { return }
            self.notifier.post(kind, sample: sample, peaks: self.monitor.currentPeaks)
        }
        Task { [notifier] in await notifier.requestAuthorization() }
```

- [ ] **Step 3: Add the test button** — in `SettingsView.swift`, inside `Section("Alerts")` after the two toggles:

```swift
                Button("Send test notification") { model.notifier.postTest() }
```

- [ ] **Step 4: Build, test and package**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass.
Run: `/Users/sammydallal/Desktop/claudeCode/ThermalWatch/build.sh`
Expected: builds and signs.

- [ ] **Step 5: Commit** — subject `feat(app): notifications for heavy pressure and sustained clock limits` (add the trailer).

- [ ] **Step 6 (controller, manual):** `./build.sh --install`; allow notifications when macOS asks; Settings → "Send test notification" shows a banner. Rebuild and reinstall once more and confirm macOS does not ask again (the "KonaClaw Dev" signature keeps the permission).

---
### Task 13: Load test

**Files:**
- Modify: `Package.swift` (add `ThermalLoad`, its tests, and the app dependency)
- Create: `Sources/ThermalCore/LoadTestRun.swift`
- Create: `Sources/ThermalLoad/StopFlag.swift`
- Create: `Sources/ThermalLoad/CPULoad.swift`
- Create: `Sources/ThermalLoad/GPULoad.swift`
- Create: `Sources/ThermalWatchApp/LoadTestModel.swift`
- Create: `Sources/ThermalWatchApp/LoadTestView.swift`
- Modify: `Sources/ThermalWatchApp/AppModel.swift` (own the load test, feed it samples, stop it on quit)
- Modify: `Sources/ThermalWatchApp/ThermalWatchApp.swift` (add window `"loadtest"`)
- Modify: `Sources/ThermalWatchApp/PopoverView.swift` (add "Load test" button)
- Test: `Tests/ThermalCoreTests/LoadTestRunTests.swift`
- Test: `Tests/ThermalLoadTests/LoadTests.swift`

**Interfaces:**
- Consumes: `LoadKind`, `StopReason`, `LoadTestResult`, `HistoryStore.insert(_:) -> Int64`, `HistoryStore.loadTests()` (Task 7); `Monitor.onSample`, `Monitor.currentPeaks`, `LiveSensors.omlxBusy`; `MetricChart`, `ChartBuilder` (Task 11).
- Produces: `LoadTestRun(kind:plannedSeconds:startedAt:)` with `hotLimitC`, `samples`, `elapsed`, `mutating feed(_:) -> StopReason?`, `clusters() -> [Cluster]`, `result(stopReason:endedAt:peaks:note:) -> LoadTestResult`; `StopFlag`; `CPULoad(threadCount:)` / `GPULoad()` (failable) with `start()`, `stop(timeout:) -> Bool`, `isRunning`; `LoadTestModel`; `LoadTestView`; window id `"loadtest"`.

- [ ] **Step 1: Update `Package.swift`** — append to `targets:`

```swift
        .target(
            name: "ThermalLoad",
            swiftSettings: mode5,
            linkerSettings: [.linkedFramework("Metal")]
        ),
        .testTarget(name: "ThermalLoadTests", dependencies: ["ThermalLoad"], swiftSettings: mode5),
```

and change the `ThermalWatchApp` target's dependencies to `["ThermalCore", "ThermalSensors", "ThermalLoad"]`.

- [ ] **Step 2: Write the failing run tests** `Tests/ThermalCoreTests/LoadTestRunTests.swift`

```swift
import Testing
@testable import ThermalCore

private func s(_ t: Double, perf: Double = 4000, gpu: Double = 1600, cpuT: Double = 80, gpuT: Double = 70,
               cpuW: Double? = 40, gpuW: Double? = 20, throttled: Bool = false) -> Sample {
    var x = Sample(timestamp: t, pressure: throttled ? 1 : 0)
    x.perfMHz = perf; x.perfBusy = 1
    x.superMHz = 4400; x.superBusy = 1
    x.gpuMHz = gpu; x.gpuBusy = 1
    x.cpuTempC = cpuT; x.gpuTempC = gpuT
    x.cpuWatts = cpuW; x.gpuWatts = gpuW
    x.state = throttled ? .throttled : .cool
    return x
}

@Test func finishesAtPlannedDuration() {
    var run = LoadTestRun(kind: .cpu, plannedSeconds: 10, startedAt: 100)
    #expect(run.feed(s(99)) == nil)          // before the start: ignored
    #expect(run.samples.isEmpty)
    for t in 100..<110 { #expect(run.feed(s(Double(t))) == nil) }
    #expect(run.feed(s(110)) == .finished)
    #expect(run.elapsed == 10)
}

@Test func stopsWhenTooHot() {
    var run = LoadTestRun(kind: .both, plannedSeconds: 600, startedAt: 0)
    #expect(run.feed(s(1, cpuT: 105)) == nil)
    #expect(run.feed(s(2, gpuT: 105.5)) == .tooHot)
}

@Test func resultSummarisesTheRun() {
    var run = LoadTestRun(kind: .cpu, plannedSeconds: 300, startedAt: 0)
    for t in 0..<100 {
        let late = t >= 40
        _ = run.feed(s(Double(t), perf: late ? 3000 : 4000, cpuT: late ? 101 : 85, cpuW: late ? 30 : 50, gpuW: nil, throttled: late))
    }
    let r = run.result(stopReason: .userStopped, endedAt: 99, peaks: [.performance: 4000, .superCores: 4400, .gpu: 1600], note: "desk")
    #expect(r.secondsToThrottle == 40)
    #expect(r.steadyDrop == ["perf": 0.25, "super": 0])
    #expect(r.peakCPUTempC == 101)
    #expect(r.startWatts == 50)
    #expect(r.endWatts == 30)
    #expect(r.ranSeconds == 99)
    #expect(r.stopReason == .userStopped)
    #expect(r.note == "desk")
    #expect(r.kind == .cpu)
}

@Test func runThatNeverThrottles() {
    var run = LoadTestRun(kind: .gpu, plannedSeconds: 5, startedAt: 0)
    for t in 0...5 { _ = run.feed(s(Double(t))) }
    let r = run.result(stopReason: .finished, endedAt: 5, peaks: [.gpu: 1600], note: "")
    #expect(r.secondsToThrottle == nil)
    #expect(r.steadyDrop == ["gpu": 0])
}
```

- [ ] **Step 3: Write the failing load tests** `Tests/ThermalLoadTests/LoadTests.swift`

```swift
import Foundation
import Testing
@testable import ThermalLoad

@Test func cpuLoadStartsAndStopsQuickly() {
    let load = CPULoad(threadCount: 2)
    load.start()
    #expect(load.isRunning)
    Thread.sleep(forTimeInterval: 0.2)
    #expect(load.stop(timeout: 1.0))
    #expect(load.isRunning == false)
    #expect(load.stop(timeout: 1.0)) // stopping twice is harmless
}

@Test func gpuLoadStartsAndStopsQuickly() throws {
    let load = try #require(GPULoad())
    load.start()
    Thread.sleep(forTimeInterval: 0.3)
    #expect(load.stop(timeout: 1.0))
    #expect(load.isRunning == false)
}
```

- [ ] **Step 4: Run to verify they fail**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch --filter "LoadTestRunTests|LoadTests"`
Expected: build FAILS (`cannot find 'LoadTestRun' in scope`, `no such module 'ThermalLoad'` until its sources exist).

- [ ] **Step 5: Implement** `Sources/ThermalCore/LoadTestRun.swift`

```swift
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
```

- [ ] **Step 6: Implement** `Sources/ThermalLoad/StopFlag.swift`

```swift
import os

/// Thread-safe "please stop" flag shared with load threads.
public final class StopFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public var isStopped: Bool { state.withLock { $0 } }
    public func stop() { state.withLock { $0 = true } }
}
```

- [ ] **Step 7: Implement** `Sources/ThermalLoad/CPULoad.swift`

```swift
import Foundation

/// One busy thread per core running a dependent floating-point chain the optimizer cannot remove.
/// No disk I/O; memory use is a few KB per thread.
public final class CPULoad {
    public let threadCount: Int
    private var flag = StopFlag()
    private var group = DispatchGroup()
    public private(set) var isRunning = false

    public init(threadCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.threadCount = max(1, threadCount)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        flag = StopFlag()
        group = DispatchGroup()
        let flag = flag
        let group = group
        for index in 0..<threadCount {
            group.enter()
            let thread = Thread {
                var x = Double(index) + 1
                while !flag.isStopped {
                    for _ in 0..<200_000 { x = x * 1.000_000_1 + 0.000_000_1 }
                    if !x.isFinite { x = 1 }
                }
                CPULoad.sink(x)
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Signals every thread and waits up to `timeout` seconds. Returns true when all exited.
    @discardableResult
    public func stop(timeout: Double = 1.0) -> Bool {
        guard isRunning else { return true }
        flag.stop()
        isRunning = false
        return group.wait(timeout: .now() + timeout) == .success
    }

    @inline(never)
    static func sink(_ x: Double) {
        if x.isNaN { print("CPULoad: unexpected NaN") }
    }
}
```

- [ ] **Step 8: Implement** `Sources/ThermalLoad/GPULoad.swift`

```swift
import Foundation
import Metal

/// A Metal compute kernel doing fused multiply-adds over a 64 MB buffer, dispatched back to back
/// with a short pause between command buffers so the UI stays responsive.
public final class GPULoad {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(device float4 *data [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float4 v = data[id];
        for (int i = 0; i < 512; i++) {
            v = fma(v, float4(1.0001f), float4(0.0001f));
            v = fma(v, float4(0.9999f), float4(-0.0001f));
        }
        data[id] = v;
    }
    """

    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private var flag = StopFlag()
    private var done = DispatchSemaphore(value: 0)
    public private(set) var isRunning = false

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "burn"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let buffer = device.makeBuffer(length: 64 << 20, options: .storageModePrivate)
        else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.buffer = buffer
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        flag = StopFlag()
        done = DispatchSemaphore(value: 0)
        let flag = flag
        let done = done
        let queue = queue
        let pipeline = pipeline
        let buffer = buffer
        let thread = Thread {
            let count = buffer.length / MemoryLayout<SIMD4<Float>>.stride
            let group = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
            while !flag.isStopped {
                autoreleasepool {
                    guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return }
                    encoder.setComputePipelineState(pipeline)
                    encoder.setBuffer(buffer, offset: 0, index: 0)
                    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: group)
                    encoder.endEncoding()
                    commands.commit()
                    commands.waitUntilCompleted()
                }
                usleep(500)
            }
            done.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    @discardableResult
    public func stop(timeout: Double = 1.0) -> Bool {
        guard isRunning else { return true }
        flag.stop()
        isRunning = false
        return done.wait(timeout: .now() + timeout) == .success
    }
}
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass (6 new).

- [ ] **Step 10: Create** `Sources/ThermalWatchApp/LoadTestModel.swift`

```swift
import Foundation
import Observation
import ThermalCore
import ThermalLoad

@MainActor
@Observable
final class LoadTestModel {
    enum Phase: Equatable {
        case idle
        case running
        case finished(LoadTestResult)
    }

    var kind: LoadKind = .both
    var minutes = 5
    var note = ""
    private(set) var phase: Phase = .idle
    private(set) var run: LoadTestRun?
    private(set) var history: [LoadTestResult] = []
    private(set) var error: String?

    @ObservationIgnored private var cpu: CPULoad?
    @ObservationIgnored private var gpu: GPULoad?
    @ObservationIgnored private let store: HistoryStore?
    @ObservationIgnored private let peaks: @MainActor () -> [Cluster: Double]

    init(store: HistoryStore?, peaks: @escaping @MainActor () -> [Cluster: Double]) {
        self.store = store
        self.peaks = peaks
        reloadHistory()
    }

    var isRunning: Bool { phase == .running }

    func start(now: Double = Date().timeIntervalSince1970) {
        guard !isRunning else { return }
        error = nil
        run = LoadTestRun(kind: kind, plannedSeconds: Double(minutes * 60), startedAt: now)
        if kind != .gpu {
            let load = CPULoad()
            load.start()
            cpu = load
        }
        if kind != .cpu {
            guard let load = GPULoad() else {
                error = "Metal is unavailable, so the GPU load cannot run."
                stop(.userStopped)
                return
            }
            load.start()
            gpu = load
        }
        phase = .running
    }

    /// Called for every Monitor sample.
    func feed(_ sample: Sample) {
        guard isRunning, var current = run else { return }
        let reason = current.feed(sample)
        run = current
        if let reason { stop(reason, now: sample.timestamp) }
    }

    func stop(_ reason: StopReason, now: Double = Date().timeIntervalSince1970) {
        cpu?.stop()
        gpu?.stop()
        cpu = nil
        gpu = nil
        guard let current = run else {
            phase = .idle
            return
        }
        var result = current.result(stopReason: reason, endedAt: now, peaks: peaks(), note: note)
        if let store, let id = try? store.insert(result) { result.id = id }
        run = nil
        phase = .finished(result)
        reloadHistory()
    }

    func reset() {
        if !isRunning { phase = .idle }
    }

    private func reloadHistory() {
        history = (try? store?.loadTests()) ?? []
    }
}
```

- [ ] **Step 11: Create** `Sources/ThermalWatchApp/LoadTestView.swift`

```swift
import SwiftUI
import ThermalCore

struct LoadTestView: View {
    let model: AppModel

    var body: some View {
        let test = model.loadTest
        VStack(alignment: .leading, spacing: 12) {
            switch test.phase {
            case .idle:
                LoadTestSetup(test: test, omlxBusy: model.sensors.omlxBusy)
            case .running:
                running(test)
            case .finished(let result):
                ResultCard(result: result)
                Button("New test") { test.reset() }
            }
            if let error = test.error { Text(error).foregroundStyle(.red) }
            Divider()
            Text("Past runs").font(.headline)
            if test.history.isEmpty {
                Text("No runs yet").foregroundStyle(.secondary)
            } else {
                List(test.history) { r in
                    HStack {
                        Text(Date(timeIntervalSince1970: r.startedAt), format: .dateTime.month().day().hour().minute())
                        Text(r.kind.label).frame(width: 80, alignment: .leading)
                        Text(r.note.isEmpty ? Format.dash : r.note).frame(width: 120, alignment: .leading)
                        Text(r.secondsToThrottle.map { "throttled at \(Format.duration($0))" } ?? "did not throttle")
                        Spacer()
                        Text("peak \(Format.temp(max(r.peakCPUTempC ?? 0, r.peakGPUTempC ?? 0)))")
                    }
                    .font(.callout.monospacedDigit())
                }
                .frame(minHeight: 140)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 620)
    }

    @ViewBuilder
    private func running(_ test: LoadTestModel) -> some View {
        let run = test.run
        let start = run?.startedAt ?? Date().timeIntervalSince1970
        let planned = run?.plannedSeconds ?? 1
        let samples = model.monitor.recent.filter { $0.timestamp >= start }
        let built = ChartBuilder.build(samples, bucket: 1, peaks: model.monitor.currentPeaks)
        let domain = start...(start + planned)
        HStack {
            Text("Running \(run?.kind.label ?? "") load").font(.headline)
            Spacer()
            Text("\(Format.duration(run?.elapsed ?? 0)) / \(Format.duration(planned))").monospacedDigit()
            Button("Stop") { test.stop(.userStopped) }.keyboardShortcut(.cancelAction)
        }
        ProgressView(value: min(1, (run?.elapsed ?? 0) / planned))
        ClockLane(bands: built.bands, domain: domain)
        MetricChart(title: "Clocks", unit: "% of peak", series: built.clocks, bands: built.bands, domain: domain)
        MetricChart(title: "Temperatures", unit: "°C", series: built.temps, bands: built.bands, domain: domain)
        MetricChart(title: "Power", unit: "W", series: built.power, bands: built.bands, domain: domain)
    }
}

private struct LoadTestSetup: View {
    @Bindable var test: LoadTestModel
    let omlxBusy: Bool
    @State private var confirmedWhileBusy = false

    var body: some View {
        Picker("Load", selection: $test.kind) {
            ForEach(LoadKind.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        Picker("Duration", selection: $test.minutes) {
            ForEach([5, 10, 20], id: \.self) { Text("\($0) min").tag($0) }
        }
        .pickerStyle(.segmented)
        TextField("Note (e.g. desk, cooling stand, Low Power mode)", text: $test.note)
        if omlxBusy && !confirmedWhileBusy {
            Text("Kona is generating — results will be skewed and the reply will slow down.")
                .foregroundStyle(.orange)
            Button("Run anyway") {
                confirmedWhileBusy = true
                test.start()
            }
        } else {
            Button("Start") { test.start() }.keyboardShortcut(.defaultAction)
        }
    }
}

private struct ResultCard: View {
    let result: LoadTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(result.kind.label) load · \(Format.duration(result.ranSeconds)) · \(result.stopReason.label)").font(.headline)
            Text(result.secondsToThrottle.map { "First throttled after \(Format.duration($0))" } ?? "Did not throttle")
            ForEach(Cluster.allCases.filter { result.steadyDrop[$0.rawValue] != nil }, id: \.self) { cluster in
                Text("\(cluster.label) clock in the last minute: \(Format.percent(result.steadyDrop[cluster.rawValue])) below peak")
            }
            Text("Peak temperature: CPU \(Format.temp(result.peakCPUTempC)), GPU \(Format.temp(result.peakGPUTempC))")
            Text("Chip power: \(Format.watts(result.startWatts)) at the start → \(Format.watts(result.endWatts)) at the end")
            if !result.note.isEmpty { Text("Note: \(result.note)").foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 12: Wire it into `AppModel.swift`** — add the property next to `notifier`:

```swift
    let loadTest: LoadTestModel
```

In `init()`, before `self.settings = settings`, create it from the locals:

```swift
        let monitor = Monitor(sensors: sensors, store: store)
        let loadTest = LoadTestModel(store: store, peaks: { [monitor] in monitor.currentPeaks })
```

replace `self.monitor = Monitor(sensors: sensors, store: store)` with:

```swift
        self.monitor = monitor
        self.loadTest = loadTest
```

and at the end of `init()` add:

```swift
        monitor.onSample = { [weak self] sample in self?.loadTest.feed(sample) }
        onShutdown.append { [weak self] in
            if self?.loadTest.isRunning == true { self?.loadTest.stop(.appQuit) }
        }
```

- [ ] **Step 13: Add the window and button** — in `ThermalWatchApp.swift` add after the `"main"` window:

```swift
        Window("Load test", id: "loadtest") {
            LoadTestView(model: model)
        }
```

In `PopoverView.swift`, in the bottom `HStack`, after the "Open window" button:

```swift
                Button("Load test") {
                    openWindow(id: "loadtest")
                    NSApp.activate()
                }
```

- [ ] **Step 14: Build, test and package**

Run: `arch -arm64 swift test --package-path /Users/sammydallal/Desktop/claudeCode/ThermalWatch`
Expected: all tests pass.
Run: `/Users/sammydallal/Desktop/claudeCode/ThermalWatch/build.sh`
Expected: builds and signs.

- [ ] **Step 15: Commit** — subject `feat: built-in CPU/GPU load test with results history` (add the trailer).

- [ ] **Step 16 (controller, manual):** `./build.sh --install`. With KonaClaw idle, run a 5-minute CPU + GPU load test. Check: clocks, temperatures and power update live; the menu-bar dot changes color when the chip throttles; Stop ends the load within about a second (Activity Monitor CPU drops); the result card appears and the run is listed under "Past runs"; a throttle event appears in the main window. Also confirm the GPU clock stays at or below 1,620 MHz under load (checks the GPU table mapping).

---

## Self-review notes

- Spec coverage: pressure/clock/SMC/token sources (Tasks 2, 3, 5, 9), throttle rule (4), events and alerts (6, 12), storage with 7-day retention and pruning (7, 9), downsampled charts, events list, CSV (8, 11), icon and popover (6, 10), settings and launch at login (10), load test with stop rules, warning, results and history (13), error handling for every source (3, 9, 10, 11).
- Deliberate deviations, recorded as rulings: fan RPM is a separate compact chart and clock-limited stretches use their own lane (Swift Charts limits); everything else follows the spec.
