import SwiftUI
import ThermalCore

struct ChartSeries: Identifiable {
    enum Style { case line, area }
    let name: String
    let color: Color
    let points: [SeriesPoint]
    /// `.area` is drawn as a soft fill from zero (System power, the total the other lines sit inside).
    var style: Style = .line
    var id: String { name }

    /// The point nearest `t`, if one is within `tolerance` seconds.
    func point(near t: Double, tolerance: Double) -> SeriesPoint? {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { points.indices.contains($0) }.map { points[$0] }
        guard let best = candidates.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(best.t - t) <= tolerance else { return nil }
        return best
    }
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

    /// `samples` sorted by time. Clocks are drawn as % of each cluster's reference peak. Throttle bands
    /// closer together than a couple of buckets are joined so they don't draw as slivers.
    static func build(_ samples: [Sample], bucket: Double, peaks: [Cluster: Double]) -> Built {
        func percent(_ cluster: Cluster) -> (Sample) -> Double? {
            { s in
                guard let mhz = s.mhz(cluster), let peak = peaks[cluster], peak > 0 else { return nil }
                return mhz / peak * 100
            }
        }
        func series(_ name: String, _ color: Color, style: ChartSeries.Style = .line, _ value: (Sample) -> Double?) -> ChartSeries {
            ChartSeries(name: name, color: color, points: Downsampler.series(samples, bucket: bucket, value: value), style: style)
        }
        // History recorded before negative readings were filtered can still hold one.
        func watts(_ value: Double?) -> Double? { value.flatMap { $0 >= 0 ? $0 : nil } }
        return Built(
            clocks: [series("Super", SeriesColor.superCores, percent(.superCores)), series("Perf", SeriesColor.cpu, percent(.performance)),
                     series("GPU", SeriesColor.gpu, percent(.gpu))],
            temps: [series("CPU", SeriesColor.cpu, { $0.cpuTempC }), series("GPU", SeriesColor.gpu, { $0.gpuTempC })],
            fans: [series("Fans", SeriesColor.neutral, { $0.fanRPM.max() })],
            power: [series("System", SeriesColor.neutral, style: .area, { watts($0.systemWatts) }), series("CPU", SeriesColor.cpu, { watts($0.cpuWatts) }),
                    series("GPU", SeriesColor.gpu, { watts($0.gpuWatts) })],
            tokens: [series("oMLX", SeriesColor.tokens, { $0.tokensPerSec })],
            bands: Downsampler.merged(Downsampler.bands(samples), gap: max(2, bucket * 2))
        )
    }
}
