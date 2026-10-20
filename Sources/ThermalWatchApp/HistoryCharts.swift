import Charts
import SwiftUI
import ThermalCore

/// Pointer time shared by every chart in a window, so one crosshair runs through all of them.
@MainActor
@Observable
final class ChartHover {
    var time: Double?
}

enum ChartAxes {
    /// Fixed y-label width, so every chart's plot area (and its time gridlines) lines up with the others.
    static let yLabelWidth: CGFloat = 34
    static let gridStroke = StrokeStyle(lineWidth: 0.5)

    /// Gridlines only. Time labels are drawn by `MetricChart` itself: on macOS 27 Swift Charts ignores a
    /// centered `AxisValueLabel` anchor and starts each label at its gridline instead of centering it.
    @AxisContentBuilder
    static func time(_ domain: ClosedRange<Double>) -> some AxisContent {
        AxisMarks(values: TimeTicks.ticks(in: domain)) { _ in
            AxisGridLine(stroke: gridStroke)
        }
    }

    @AxisContentBuilder
    static func values(_ ticks: [Double]) -> some AxisContent {
        AxisMarks(position: .trailing, values: ticks) { value in
            AxisGridLine(stroke: gridStroke)
            AxisValueLabel {
                Text(value.as(Double.self).map(compact) ?? "")
                    .monospacedDigit()
                    .frame(width: yLabelWidth, alignment: .leading)
            }
        }
    }

    /// An empty y-axis as wide as `values(_:)`, for lanes that should line up with the charts.
    @AxisContentBuilder
    static func blankValues() -> some AxisContent {
        AxisMarks(position: .trailing, values: [0.0]) { _ in
            AxisValueLabel { Color.clear.frame(width: yLabelWidth, height: 1) }
        }
    }

    /// "9:32 PM" for short ranges, "4 PM" (or "Oct 18" at midnight) for a day, "Mon 13" for a week.
    static func timeLabel(_ t: Double, step: Double) -> String {
        let date = Date(timeIntervalSince1970: t)
        if step < 3600 { return date.formatted(.dateTime.hour().minute()) }
        if step >= 86_400 { return date.formatted(.dateTime.weekday(.abbreviated).day()) }
        if Calendar.current.component(.hour, from: date) == 0 { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.hour())
    }

    /// Short tick labels: "6k" instead of "6,000".
    static func compact(_ v: Double) -> String {
        guard abs(v) >= 1000 else { return "\(Int(v.rounded()))" }
        let k = v / 1000
        return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
    }

    static func valueText(_ v: Double?, unit: String) -> String {
        guard let v, v.isFinite else { return Format.dash }
        switch unit {
        case "%": return "\(Int(v.rounded()))%"
        case "°C": return Format.temp(v)
        case "W": return Format.watts(v)
        case "rpm": return "\(Format.grouped(Int(v.rounded()))) rpm"
        default: return "\(Int(v.rounded())) \(unit)"
        }
    }
}

struct MetricChart: View {
    let title: String
    let unit: String
    let series: [ChartSeries]
    let bands: [StateBand]
    let domain: ClosedRange<Double>
    var height: CGFloat = 110
    var note: String?
    /// Only the bottom chart of a stack needs time labels; the others share its gridlines.
    var showsTimeLabels = true
    /// False for readings like temperature, where zero isn't a meaningful baseline.
    var includesZero = true

    @Environment(ChartHover.self) private var hover: ChartHover?
    @Environment(\.colorScheme) private var colorScheme
    @State private var pointerHere = false

    private var yScale: NiceScale.Scale {
        let points = series.flatMap(\.points)
        let lows = points.map { $0.min }, highs = points.map { $0.max }
        return NiceScale.scale(min: lows.min() ?? 0, max: highs.max() ?? 0, includesZero: includesZero)
    }

    private var hoverTime: Double? {
        hover?.time.flatMap { domain.contains($0) ? $0 : nil }
    }

    /// About two buckets: how far from the pointer a point can be and still count as "at" it.
    private var tolerance: Double { (domain.upperBound - domain.lowerBound) / 150 }

    private func value(_ s: ChartSeries) -> Double? {
        if let t = hoverTime { return s.point(near: t, tolerance: tolerance)?.mean }
        return s.points.last?.mean
    }

    var body: some View {
        let yScale = self.yScale
        VStack(alignment: .leading, spacing: 4) {
            header
            Chart {
                ForEach(bands) { band in
                    RectangleMark(xStart: .value("Start", max(band.start, domain.lowerBound)),
                                  xEnd: .value("End", min(band.end, domain.upperBound)))
                        .foregroundStyle(band.color.swiftUIColor.opacity(colorScheme == .dark ? 0.1 : 0.13))
                }
                ForEach(series) { s in
                    ForEach(s.points) { p in
                        switch s.style {
                        case .area:
                            AreaMark(x: .value("Time", p.t), yStart: .value(unit, 0), yEnd: .value(unit, p.mean),
                                     series: .value("Series", "\(s.name)#\(p.segment)"))
                                .foregroundStyle(Color.primary.opacity(0.1))
                        case .line:
                            AreaMark(x: .value("Time", p.t), yStart: .value(unit, p.min), yEnd: .value(unit, p.max),
                                     series: .value("Series", "\(s.name) range#\(p.segment)"))
                                .foregroundStyle(s.color.opacity(0.12))
                            LineMark(x: .value("Time", p.t), y: .value(unit, p.mean), series: .value("Series", "\(s.name)#\(p.segment)"))
                                .foregroundStyle(s.color)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        }
                    }
                }
                if let t = hoverTime {
                    RuleMark(x: .value("Time", t))
                        .foregroundStyle(Color.primary.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    ForEach(series.filter { $0.style == .line }) { s in
                        if let p = s.point(near: t, tolerance: tolerance) {
                            PointMark(x: .value("Time", p.t), y: .value(unit, p.mean))
                                .symbol {
                                    Circle().fill(s.color).frame(width: 7, height: 7)
                                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                }
                        }
                    }
                }
            }
            .chartXScale(domain: domain)
            .chartXAxis { ChartAxes.time(domain) }
            .chartYScale(domain: yScale.lower...yScale.upper)
            .chartYAxis { ChartAxes.values(yScale.ticks) }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let location) = phase,
                                  let t: Double = proxy.value(atX: location.x - plot.minX), domain.contains(t) else {
                                hover?.time = nil
                                pointerHere = false
                                return
                            }
                            hover?.time = t
                            pointerHere = true
                        }
                    if showsTimeLabels {
                        let step = TimeTicks.stride(span: domain.upperBound - domain.lowerBound)
                        ForEach(TimeTicks.ticks(in: domain), id: \.self) { t in
                            if let x = proxy.position(forX: t) {
                                Text(ChartAxes.timeLabel(t, step: step))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                    .position(x: plot.minX + x, y: plot.maxY + 11)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: height)
            .padding(.bottom, showsTimeLabels ? 18 : 0)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if let label = note ?? (unit.isEmpty ? nil : unit) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(series) { s in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: s.style == .area ? 2 : 4)
                        .fill(s.style == .area ? Color.primary.opacity(0.18) : s.color)
                        .frame(width: s.style == .area ? 10 : 8, height: 8)
                    Text(s.name).foregroundStyle(.secondary)
                    Text(ChartAxes.valueText(value(s), unit: unit)).monospacedDigit()
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
            if pointerHere, let t = hoverTime {
                Text(Date(timeIntervalSince1970: t), format: .dateTime.month(.abbreviated).day().hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Orange marks wherever clocks were held down (the spec's "hatched" stretches).
struct ClockLane: View {
    let bands: [StateBand]
    let domain: ClosedRange<Double>

    var body: some View {
        let limited = Downsampler.merged(bands.filter(\.clockLimited), gap: (domain.upperBound - domain.lowerBound) / 300,
                                         sameKind: { _, _ in true })
        VStack(alignment: .leading, spacing: 3) {
            Text("Clocks held down").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(limited) { band in
                    RectangleMark(xStart: .value("Start", max(band.start, domain.lowerBound)),
                                  xEnd: .value("End", min(band.end, domain.upperBound)),
                                  yStart: .value("y", 0), yEnd: .value("y", 1))
                        .foregroundStyle(StatusColor.orange.swiftUIColor)
                        .cornerRadius(2)
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartYAxis { ChartAxes.blankValues() }
            .frame(height: 8)
        }
    }
}
