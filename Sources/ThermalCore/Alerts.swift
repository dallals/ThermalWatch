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
