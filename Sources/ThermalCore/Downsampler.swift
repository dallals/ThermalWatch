import Foundation

public struct SeriesPoint: Equatable, Sendable, Identifiable {
    public var t: Double
    public var min: Double
    public var max: Double
    public var mean: Double
    /// Points with the same segment are joined by a line; a new segment starts after a gap in the data.
    public var segment: Int
    public init(t: Double, min: Double, max: Double, mean: Double, segment: Int = 0) {
        self.t = t
        self.min = min
        self.max = max
        self.mean = mean
        self.segment = segment
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
    /// Samples must be sorted by time. Samples where `value` is nil are skipped. A gap of more than
    /// `gapBuckets` buckets (and at least 3 s) between points starts a new segment, so the chart doesn't
    /// draw a line across time with no data (oMLX idle, the app not running).
    public static func series(_ samples: [Sample], bucket: Double, gapBuckets: Double = 2,
                              value: (Sample) -> Double?) -> [SeriesPoint] {
        guard bucket > 0 else { return [] }
        let maxGap = Swift.max(3, gapBuckets * bucket)
        var out: [SeriesPoint] = []
        var key: Double?
        var values: [Double] = []
        var segment = 0
        func emit() {
            guard let key, !values.isEmpty else { return }
            if let last = out.last, key - last.t > maxGap { segment += 1 }
            out.append(SeriesPoint(t: key, min: values.min()!, max: values.max()!,
                                   mean: values.reduce(0, +) / Double(values.count), segment: segment))
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
