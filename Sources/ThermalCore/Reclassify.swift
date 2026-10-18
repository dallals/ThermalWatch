import Foundation

/// Replays stored samples through the current detection rules, the same way `Monitor.tick` classifies a
/// live sample: reference peaks come from the table maximum plus every earlier busy sample, the detector
/// sees the few samples before, and events are rebuilt from the reclassified states. Used after a rule
/// change so the stored history and event list read as if recorded under the new rules.
public enum Reclassify {
    public static func run(_ samples: [Sample], tableMax: [Cluster: Double],
                           detector: ThrottleDetector = ThrottleDetector()) -> (samples: [Sample], events: [ThrottleEvent]) {
        var peaks = PeakTracker(tableMax: tableMax, busyThreshold: detector.thresholds.busy)
        var builder = EventBuilder(busyThreshold: detector.thresholds.busy)
        let window = Int(detector.thresholds.busySeconds) + 5
        var out: [Sample] = []
        var events: [ThrottleEvent] = []
        out.reserveCapacity(samples.count)
        for original in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            var s = original
            let used = peaks.peaks()
            let c = detector.classify(current: s, recent: Array(out.suffix(window)), peaks: used)
            s.state = c.state
            s.clockLimited = c.clockLimited
            peaks.observe(s)
            if let closed = builder.feed(s, peaks: used) { events.append(closed) }
            out.append(s)
        }
        if let open = builder.flush() { events.append(open) }
        return (out, events)
    }
}
