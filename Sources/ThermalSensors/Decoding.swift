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
