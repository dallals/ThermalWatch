import SwiftUI
import ThermalCore

struct LoadTestView: View {
    let model: AppModel

    var body: some View {
        let test = model.loadTest
        VStack(alignment: .leading, spacing: 12) {
            switch test.phase {
            case .idle:
                LoadTestSetup(test: test, omlxBusy: model.sensors.omlxBusy)
            case .running:
                running(test)
            case .finished(let result):
                ResultCard(result: result)
                Button("New test") { test.reset() }
            }
            if let error = test.error { Text(error).foregroundStyle(.red) }
            Divider()
            Text("Past runs").font(.headline)
            if test.history.isEmpty {
                Text("No runs yet").foregroundStyle(.secondary)
            } else {
                List(test.history) { r in
                    HStack {
                        Text(Date(timeIntervalSince1970: r.startedAt), format: .dateTime.month().day().hour().minute())
                        Text(r.kind.label).frame(width: 80, alignment: .leading)
                        Text(r.note.isEmpty ? Format.dash : r.note).frame(width: 120, alignment: .leading)
                        Text(r.secondsToThrottle.map { "throttled at \(Format.duration($0))" } ?? "did not throttle")
                        Spacer()
                        Text("peak \(Format.temp(max(r.peakCPUTempC ?? 0, r.peakGPUTempC ?? 0)))")
                    }
                    .font(.callout.monospacedDigit())
                }
                .frame(minHeight: 140)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 620)
    }

    @ViewBuilder
    private func running(_ test: LoadTestModel) -> some View {
        let run = test.run
        let start = run?.startedAt ?? Date().timeIntervalSince1970
        let planned = run?.plannedSeconds ?? 1
        let samples = model.monitor.recent.filter { $0.timestamp >= start }
        let built = ChartBuilder.build(samples, bucket: 1, peaks: model.monitor.currentPeaks)
        let domain = start...(start + planned)
        HStack {
            Text("Running \(run?.kind.label ?? "") load").font(.headline)
            Spacer()
            Text("\(Format.duration(run?.elapsed ?? 0)) / \(Format.duration(planned))").monospacedDigit()
            Button("Stop") { test.stop(.userStopped) }.keyboardShortcut(.cancelAction)
        }
        ProgressView(value: min(1, (run?.elapsed ?? 0) / planned))
        ClockLane(bands: built.bands, domain: domain)
        MetricChart(title: "Clocks", unit: "% of peak", series: built.clocks, bands: built.bands, domain: domain)
        MetricChart(title: "Temperatures", unit: "°C", series: built.temps, bands: built.bands, domain: domain)
        MetricChart(title: "Power", unit: "W", series: built.power, bands: built.bands, domain: domain)
    }
}

private struct LoadTestSetup: View {
    @Bindable var test: LoadTestModel
    let omlxBusy: Bool
    @State private var confirmedWhileBusy = false

    var body: some View {
        Picker("Load", selection: $test.kind) {
            ForEach(LoadKind.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        Picker("Duration", selection: $test.minutes) {
            ForEach([5, 10, 20], id: \.self) { Text("\($0) min").tag($0) }
        }
        .pickerStyle(.segmented)
        TextField("Note (e.g. desk, cooling stand, Low Power mode)", text: $test.note)
        if omlxBusy && !confirmedWhileBusy {
            Text("Kona is generating — results will be skewed and the reply will slow down.")
                .foregroundStyle(.orange)
            Button("Run anyway") {
                confirmedWhileBusy = true
                test.start()
            }
        } else {
            Button("Start") { test.start() }.keyboardShortcut(.defaultAction)
        }
    }
}

private struct ResultCard: View {
    let result: LoadTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(result.kind.label) load · \(Format.duration(result.ranSeconds)) · \(result.stopReason.label)").font(.headline)
            Text(result.secondsToThrottle.map { "First throttled after \(Format.duration($0))" } ?? "Did not throttle")
            ForEach(Cluster.allCases.filter { result.steadyDrop[$0.rawValue] != nil }, id: \.self) { cluster in
                Text("\(cluster.label) clock in the last minute: \(Format.percent(result.steadyDrop[cluster.rawValue])) below peak")
            }
            Text("Peak temperature: CPU \(Format.temp(result.peakCPUTempC)), GPU \(Format.temp(result.peakGPUTempC))")
            Text("Chip power: \(Format.watts(result.startWatts)) at the start → \(Format.watts(result.endWatts)) at the end")
            if !result.note.isEmpty { Text("Note: \(result.note)").foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
