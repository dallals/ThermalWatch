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
