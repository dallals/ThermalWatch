import AppKit
import SwiftUI
import ThermalCore
import UniformTypeIdentifiers

struct MainWindowView: View {
    let model: AppModel
    @State private var data = WindowData()
    @State private var hover = ChartHover()

    var body: some View {
        let built = data.built
        let domain = data.domain
        let unavailable = model.monitor.unavailable
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Range", selection: $data.range) {
                    ForEach(TimeRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
                Spacer()
                Button("Export CSV…", action: exportCSV).disabled(data.samples.isEmpty)
            }
            HStack {
                Text("Back in time").font(.caption)
                Slider(value: $data.endOffset, in: 0...max(1, maxOffset))
                Text(data.endOffset < 1 ? "Live" : "−" + Format.duration(data.endOffset))
                    .font(.caption.monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
            }
            if let error = model.monitor.storeError ?? model.storeOpenError {
                Text("History not saving: \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ClockLane(bands: built.bands, domain: domain)
                        MetricChart(title: "Clocks", unit: "%", series: built.clocks, bands: built.bands, domain: domain,
                                    note: unavailable.contains("clocks") ? "Clock data unavailable" : "% of reference peak", showsTimeLabels: false)
                        MetricChart(title: "Temperatures", unit: "°C", series: built.temps, bands: built.bands, domain: domain,
                                    note: unavailable.contains("temps") ? "Temperature data unavailable" : nil, showsTimeLabels: false, includesZero: false)
                        MetricChart(title: "Fans", unit: "rpm", series: built.fans, bands: built.bands, domain: domain, height: 60,
                                    note: unavailable.contains("fans") ? "Fan data unavailable" : nil, showsTimeLabels: false)
                        MetricChart(title: "Power", unit: "W", series: built.power, bands: built.bands, domain: domain,
                                    note: unavailable.contains("power") ? "Power data unavailable" : nil, showsTimeLabels: false)
                        MetricChart(title: "oMLX speed", unit: "tok/s", series: built.tokens, bands: built.bands, domain: domain, height: 90,
                                    note: unavailable.contains("tokens") ? "oMLX not reachable" : nil)
                    }
                    .environment(hover)
                    .padding(.trailing, 6)
                }
                EventsList(events: data.events) { data.center(on: $0) }
                    .frame(width: 300)
            }
        }
        .padding(14)
        .frame(minWidth: 1000, minHeight: 760)
        .task(id: "\(data.range.rawValue)-\(Int(data.endOffset))") {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            await data.reload(model: model)
        }
        .task {
            var lastPoll = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // Long live ranges reload the whole range, so poll them far less often.
                let interval: TimeInterval = data.range.rawValue <= 3600 ? 2 : 30
                guard data.endOffset < 1, !data.isLoading, Date().timeIntervalSince(lastPoll) >= interval - 0.5 else { continue }
                lastPoll = Date()
                await data.reload(model: model)
            }
        }
    }

    private var maxOffset: Double {
        Double(model.settings.retentionDays) * 86_400 - data.range.rawValue
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "thermalwatch-\(Int(data.end)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let samples = data.samples
        Task.detached(priority: .userInitiated) {
            do {
                try CSVExport.csv(samples).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Could not export CSV"
                    alert.informativeText = message
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}
