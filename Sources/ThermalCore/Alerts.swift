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
    private var pendingHeavy = false
    private var pendingSustained = false

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
            pendingSustained = false
        }
        if !heavy { pendingHeavy = false }
        let sustained = limitedSince.map { s.timestamp - $0 + 1 >= sustainSeconds } ?? false

        if enteredHeavy && heavyEnabled { pendingHeavy = true }
        if sustained && !sustainedConsumed && sustainedEnabled { pendingSustained = true }
        if sustained { sustainedConsumed = true }

        // A kind held back only by minInterval stays pending until it expires and the condition still holds.
        if let last = lastAlert, s.timestamp - last < minInterval { return nil }
        let kind: AlertKind
        if pendingHeavy {
            kind = .heavyPressure
            pendingHeavy = false
        } else if pendingSustained {
            kind = .sustainedClockLimit
            pendingSustained = false
        } else {
            return nil
        }
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
            var limited: [(Cluster, Double)] = []
            for c in Cluster.allCases where s.clockReflectsHeat(c) {
                guard let mhz = s.mhz(c), let busy = s.busy(c), busy > Thresholds.standard.busy,
                      let peak = peaks[c], peak > 0 else { continue }
                if mhz < peak * (1 - Thresholds.standard.throttleDrop) { limited.append((c, mhz / peak)) }
            }
            for (c, share) in limited.sorted(by: { $0.1 < $1.1 }) {
                text += " \(c.label) at \(Int((share * 100).rounded()))% of peak."
            }
            if s.gpuThermalCapped == true { text += " GPU thermally capped." }
            return text
        }
    }
}
