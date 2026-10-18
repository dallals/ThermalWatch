import Charts
import SwiftUI
import ThermalCore

enum TimeAxis {
    @AxisContentBuilder
    static func marks(range: TimeRange = .tenMinutes) -> some AxisContent {
        let showDate = range.rawValue >= 86_400
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let t = value.as(Double.self) {
                    Text(Date(timeIntervalSince1970: t), format: showDate ? .dateTime.month(.abbreviated).day().hour() : .dateTime.hour().minute())
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
    var range: TimeRange = .tenMinutes
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
                        LineMark(x: .value("Time", p.t), y: .value(unit, p.mean), series: .value("Series", "\(s.name)#\(p.segment)"))
                            .foregroundStyle(s.color)
                    }
                }
            }
            .chartXScale(domain: domain)
            .chartXAxis { TimeAxis.marks(range: range) }
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
