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

    /// Bucket size for drawing: about 300-360 points across the range, so lines read as a trend
    /// instead of second-by-second noise; each bucket's min/max is still drawn as a faint envelope.
    public var bucketSeconds: Double {
        switch self {
        case .tenMinutes: 2
        case .hour: 10
        case .sixHours: 60
        case .day: 240
        case .week: 1800
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

    /// Joins bands that would draw as the same color and are at most `gap` seconds apart, so a stretch of
    /// throttling reads as one block instead of slivers split by one-sample blips.
    public static func merged(_ bands: [StateBand], gap: Double,
                              sameKind: (StateBand, StateBand) -> Bool = { $0.color == $1.color }) -> [StateBand] {
        var out: [StateBand] = []
        for band in bands {
            if var last = out.last, sameKind(last, band), band.start - last.end <= gap {
                last.end = Swift.max(last.end, band.end)
                out[out.count - 1] = last
            } else {
                out.append(band)
            }
        }
        return out
    }
}

extension StateBand {
    public var color: StatusColor { StatusColor.color(pressure: pressure, clockLimited: clockLimited, warm: false) }
}

/// Evenly spaced time-axis ticks on round local clock times (every 2 min, 10 min, 1 h, ...).
public enum TimeTicks {
    static let strides: [Double] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10_800, 14_400, 21_600, 43_200, 86_400]

    /// The smallest round stride that gives at most `maxTicks` ticks across `span` seconds.
    public static func stride(span: Double, maxTicks: Int = 7) -> Double {
        strides.first { span / $0 <= Double(maxTicks) } ?? (span / Double(maxTicks) / 86_400).rounded(.up) * 86_400
    }

    public static func ticks(in domain: ClosedRange<Double>, maxTicks: Int = 7, timeZone: TimeZone = .current) -> [Double] {
        let step = stride(span: domain.upperBound - domain.lowerBound, maxTicks: maxTicks)
        let offset = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: domain.lowerBound)))
        var t = ((domain.lowerBound + offset) / step).rounded(.up) * step - offset
        var out: [Double] = []
        while t <= domain.upperBound {
            out.append(t)
            t += step
        }
        return out
    }
}

/// A y-axis range that hugs the data and ends on round numbers, with about `intervals` gridline steps.
public enum NiceScale {
    public struct Scale: Equatable, Sendable {
        public var lower: Double
        public var upper: Double
        public var step: Double
        public var ticks: [Double] { Swift.stride(from: lower, through: upper + step / 2, by: step).map { $0 } }
    }

    public static func scale(min: Double, max: Double, includesZero: Bool, intervals: Int = 3) -> Scale {
        var lo = includesZero ? Swift.min(0, min) : min
        var hi = Swift.max(max, lo + 1)
        let step = nice((hi - lo) / Double(intervals))
        lo = (lo / step).rounded(.down) * step
        hi = (hi / step).rounded(.up) * step
        return Scale(lower: lo, upper: hi, step: step)
    }

    /// The smallest of 1, 2, 2.5, 5 (times a power of ten) that is at least `raw`.
    static func nice(_ raw: Double) -> Double {
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        return [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw - 1e-9 } ?? 10 * magnitude
    }
}
