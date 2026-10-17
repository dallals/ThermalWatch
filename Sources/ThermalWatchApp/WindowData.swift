import Foundation
import Observation
import ThermalCore

@MainActor
@Observable
final class WindowData {
    var range: TimeRange = .tenMinutes
    /// Seconds back from now that the right edge of the charts shows (0 = live).
    var endOffset: Double = 0
    private(set) var samples: [Sample] = []
    private(set) var events: [ThrottleEvent] = []
    private(set) var built = ChartBuilder.Built.empty
    private(set) var end: Double = Date().timeIntervalSince1970
    private(set) var isLoading = false
    @ObservationIgnored private var generation = 0

    var domain: ClosedRange<Double> { (end - range.rawValue)...end }

    func reload(model: AppModel) async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        let now = Date().timeIntervalSince1970
        let end = now - endOffset
        let start = end - range.rawValue
        let bucket = range.bucketSeconds
        let peaks = model.monitor.currentPeaks
        let live: [Sample]? = (endOffset == 0 && range.rawValue <= Monitor.memorySeconds)
            ? model.monitor.recent.filter { $0.timestamp >= start }
            : nil
        let store = model.store
        let openEvent = model.monitor.openEvent

        let work = Task.detached(priority: .userInitiated) { () -> ([Sample], [ThrottleEvent], ChartBuilder.Built) in
            let samples = live ?? ((try? store?.samples(from: start, to: end)) ?? [])
            var events = (try? store?.events(from: start, to: end)) ?? []
            if let openEvent, openEvent.end >= start { events.insert(openEvent, at: 0) }
            return (samples, events, ChartBuilder.build(samples, bucket: bucket, peaks: peaks))
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }

        guard mine == generation, !Task.isCancelled else { return }
        samples = result.0
        events = result.1
        built = result.2
        self.end = end
    }

    /// Moves the charts so `event` sits in the middle of the current range.
    func center(on event: ThrottleEvent, now: Double = Date().timeIntervalSince1970) {
        let middle = (event.start + event.end) / 2
        endOffset = max(0, now - (middle + range.rawValue / 2))
    }
}
