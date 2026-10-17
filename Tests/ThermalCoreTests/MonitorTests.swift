import Foundation
import Testing
@testable import ThermalCore

final class FakeSensors: SensorSuite {
    var tableMax: [Cluster: Double] = [.performance: 4000]
    var unavailable: Set<String> = []
    var omlxBusy = false
    var make: (Double) -> Sample = { Sample(timestamp: $0, pressure: 0) }
    func read(now: Double) async -> Sample { make(now) }
}

final class FakeStore: HistoryWriting {
    var samples: [Sample] = []
    var events: [ThrottleEvent] = []
    var failInserts = false
    var observed: [Cluster: Double] = [:]
    var pruneCutoffs: [Double] = []
    func insert(_ s: [Sample]) throws {
        if failInserts { throw StoreError.sqlite("disk full") }
        samples += s
    }
    func insert(_ e: ThrottleEvent) throws {
        if failInserts { throw StoreError.sqlite("disk full") }
        events.append(e)
    }
    func maxBusyMHz(since: Double, busyAbove: Double) throws -> [Cluster: Double] { observed }
    func prune(olderThan cutoff: Double) throws { pruneCutoffs.append(cutoff) }
}

private func busyPerf(_ mhz: Double) -> (Double) -> Sample {
    { t in
        var s = Sample(timestamp: t, pressure: 0)
        s.perfMHz = mhz
        s.perfBusy = 0.9
        return s
    }
}

@MainActor
private func ticks(_ m: Monitor, _ times: ClosedRange<Int>) async {
    for t in times { await m.tick(now: Double(t)) }
}

@Test @MainActor func tickClassifiesAndKeepsLatest() async {
    let sensors = FakeSensors()
    // Cool at first (this becomes the observed peak), then the clock drops 25% under the same load.
    sensors.make = { t in busyPerf(t < 2 ? 4000 : 3000)(t) }
    let m = Monitor(sensors: sensors, store: nil, now: 0)
    await ticks(m, 0...4)
    #expect(m.latest?.state == .throttled)
    #expect(m.latest?.clockLimited == true)
    #expect(m.recent.count == 5)
    #expect(m.currentPeaks[.performance] == 4000)
}

@Test @MainActor func storePeakReplacesTableMax() async {
    let sensors = FakeSensors()
    sensors.make = busyPerf(2700)
    let store = FakeStore()
    store.observed = [.performance: 3000]
    let m = Monitor(sensors: sensors, store: store, now: 0)
    #expect(store.pruneCutoffs == [-7 * 86_400])
    await ticks(m, 0...5)
    #expect(m.latest?.state == .warm)
    #expect(m.latest?.clockLimited == false)
}

@Test @MainActor func recentKeepsOneHour() async {
    let m = Monitor(sensors: FakeSensors(), store: nil, now: 0)
    await m.tick(now: 0)
    await m.tick(now: 3601)
    #expect(m.recent.map(\.timestamp) == [3601])
}

@Test @MainActor func samplesFlushEveryTenSeconds() async {
    let store = FakeStore()
    let m = Monitor(sensors: FakeSensors(), store: store, now: 0)
    await ticks(m, 0...9)
    #expect(store.samples.isEmpty)
    await m.tick(now: 10)
    #expect(store.samples.count == 11)
}

@Test @MainActor func closedEventsArePersistedAndReported() async {
    let sensors = FakeSensors()
    sensors.make = { t in Sample(timestamp: t, pressure: t <= 2 ? 1 : 0) }
    let store = FakeStore()
    let m = Monitor(sensors: sensors, store: store, now: 0)
    var closed: [ThrottleEvent] = []
    m.onEventClosed = { closed.append($0) }
    await ticks(m, 0...11)
    #expect(m.openEvent?.start == 0)
    await m.tick(now: 12)
    #expect(store.events.map(\.start) == [0])
    #expect(closed.map(\.end) == [2])
    #expect(m.openEvent == nil)
}

@Test @MainActor func alertsAndSampleCallbacks() async {
    let sensors = FakeSensors()
    sensors.make = { Sample(timestamp: $0, pressure: 2) }
    let m = Monitor(sensors: sensors, store: nil, now: 0)
    var alerts: [AlertKind] = []
    var seen = 0
    m.onAlert = { kind, _ in alerts.append(kind) }
    m.onSample = { _ in seen += 1 }
    await ticks(m, 0...2)
    #expect(alerts == [.heavyPressure])
    #expect(seen == 3)
}

@Test @MainActor func tickCompletesWhenTokensUnavailable() async {
    let sensors = FakeSensors()
    sensors.unavailable = ["tokens"]
    let m = Monitor(sensors: sensors, store: nil, now: 0)
    await m.tick(now: 0)
    #expect(m.latest?.tokensPerSec == nil)
    #expect(m.unavailable == ["tokens"])
}

@Test @MainActor func storeFailureKeepsRunningAndRetries() async {
    let store = FakeStore()
    store.failInserts = true
    let m = Monitor(sensors: FakeSensors(), store: store, now: 0)
    await ticks(m, 0...10)
    #expect(m.storeError != nil)
    #expect(m.recent.count == 11)
    store.failInserts = false
    await m.tick(now: 20)
    #expect(store.samples.count == 12)
    #expect(m.storeError == nil)
}

@Test @MainActor func shutdownClosesOpenEventAndFlushes() async {
    let sensors = FakeSensors()
    sensors.make = { Sample(timestamp: $0, pressure: 1) }
    let store = FakeStore()
    let m = Monitor(sensors: sensors, store: store, now: 0)
    await ticks(m, 0...3)
    m.shutdown(now: 4)
    #expect(store.events.map(\.end) == [3])
    #expect(store.samples.count == 4)
    #expect(m.openEvent == nil)
}
