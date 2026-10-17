import AppKit
import Charts
import SwiftUI
import ThermalCore

struct PopoverView: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

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
            Text("oMLX  \(model.monitor.unavailable.contains("tokens") ? Format.dash : Format.tokens(sample?.tokensPerSec))").font(.callout.monospacedDigit())
            if model.loadTest.isRunning {
                HStack {
                    Text("Load test running — \(Self.clock(max(0, (model.loadTest.run?.plannedSeconds ?? 0) - (model.loadTest.run?.elapsed ?? 0)))) left")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Stop") { model.loadTest.stop(.userStopped) }
                }
                .font(.callout)
            }
            Sparkline(samples: Array(model.monitor.recent.suffix(600)), peaks: peaks)
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
                Button("Open window") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Button("Load test") {
                    openWindow(id: "loadtest")
                    NSApp.activate()
                }
                SettingsLink { Text("Settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 390)
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

/// Last 10 minutes: the lowest clock (as % of reference peak) among busy clusters,
/// falling back to Perf when nothing is busy, with throttled stretches shaded.
private struct Sparkline: View {
    let samples: [Sample]
    let peaks: [Cluster: Double]

    private func share(_ s: Sample) -> Double? {
        var lowest: Double?
        for c in Cluster.allCases where s.clockReflectsHeat(c) {
            guard let mhz = s.mhz(c), let busy = s.busy(c), busy > Thresholds.standard.busy,
                  let peak = peaks[c], peak > 0 else { continue }
            lowest = min(lowest ?? .infinity, mhz / peak * 100)
        }
        if let lowest { return lowest }
        if let mhz = s.perfMHz, let peak = peaks[.performance], peak > 0 { return mhz / peak * 100 }
        return nil
    }

    var body: some View {
        let bands = Downsampler.bands(samples)
        Chart {
            ForEach(bands) { band in
                RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end))
                    .foregroundStyle(StatusColor.color(pressure: band.pressure, clockLimited: band.clockLimited, warm: false).swiftUIColor.opacity(0.25))
            }
            ForEach(samples, id: \.timestamp) { s in
                if let pct = share(s) {
                    LineMark(x: .value("Time", s.timestamp), y: .value("% of peak", pct))
                }
            }
        }
        .chartXScale(domain: .automatic(includesZero: false))
        .chartYScale(domain: 0...110)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 44)
    }
}
