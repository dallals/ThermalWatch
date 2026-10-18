import Testing
@testable import ThermalCore

private let peaks: [Cluster: Double] = [.performance: 4000, .gpu: 1600]

private func s(_ t: Double, throttled: Bool, pressure: Int = 1, perf: Double? = nil, busy: Double = 0.9, tps: Double? = nil) -> Sample {
    var x = Sample(timestamp: t, pressure: throttled ? pressure : 0)
    x.state = throttled ? .throttled : .cool
    x.perfMHz = perf
    x.perfBusy = perf == nil ? nil : busy
    x.tokensPerSec = tps
    return x
}

@Test func eventClosesTenSecondsAfterLastThrottledSample() throws {
    var b = EventBuilder()
    var closed: [ThrottleEvent] = []
    for t in 0...4 { if let e = b.feed(s(Double(t), throttled: true), peaks: peaks) { closed.append(e) } }
    for t in 5...13 { if let e = b.feed(s(Double(t), throttled: false), peaks: peaks) { closed.append(e) } }
    #expect(closed.isEmpty)
    #expect(b.current?.start == 0)
    let closedAt14 = b.feed(s(14, throttled: false), peaks: peaks)
    let e = try #require(closedAt14)
    #expect(e.start == 0)
    #expect(e.end == 4)
    #expect(e.duration == 5)
    #expect(e.worstPressure == 1)
    #expect(b.current == nil)
}

@Test func rethrottleWithinTenSecondsExtendsEvent() {
    var b = EventBuilder()
    _ = b.feed(s(0, throttled: true, pressure: 1), peaks: peaks)
    _ = b.feed(s(5, throttled: false), peaks: peaks)
    _ = b.feed(s(9, throttled: true, pressure: 3), peaks: peaks)
    #expect(b.current?.start == 0)
    #expect(b.current?.end == 9)
    #expect(b.current?.worstPressure == 3)
}

@Test func eventSplitsAcrossGap() throws {
    var b = EventBuilder()
    _ = b.feed(s(0, throttled: true), peaks: peaks)
    let closedOld = b.feed(s(300, throttled: true), peaks: peaks)
    let old = try #require(closedOld)
    #expect(old.start == 0)
    #expect(old.end == 0)
    #expect(b.current?.start == 300)
}

@Test func clockDropUsesBusyClustersOnly() {
    #expect(EventBuilder.clockDrop(s(0, throttled: true, perf: 3000), peaks: peaks, busyThreshold: 0.6) == 0.25)
}

@Test func idleClusterDoesNotCountAsDrop() {
    #expect(EventBuilder.clockDrop(s(0, throttled: true, perf: 800, busy: 0.1), peaks: peaks, busyThreshold: 0.6) == 0)
}

@Test func eventTracksTokensBeforeAndDuring() throws {
    var b = EventBuilder()
    _ = b.feed(s(0, throttled: false, tps: 50), peaks: peaks)   // older than 60 s before start: dropped
    for (i, tps) in [40.0, 42, 40, 42, 41].enumerated() { _ = b.feed(s(100 + Double(i), throttled: false, tps: tps), peaks: peaks) }
    _ = b.feed(s(105, throttled: true, perf: 3000, tps: 30), peaks: peaks)
    for (i, tps) in [28.0, 30, 28, 29].enumerated() { _ = b.feed(s(106 + Double(i), throttled: true, perf: 3200, tps: tps), peaks: peaks) }
    let flushed = b.flush()
    let e = try #require(flushed)
    #expect(e.tokensBefore == 41)
    #expect(e.tokensDuring == 29)
    #expect(e.maxClockDrop == 0.25)
    let second = b.flush()
    #expect(second == nil)
}

@Test func gpuClockDropCountsOnlyWhileThermallyCapped() {
    var x = Sample(timestamp: 0, pressure: 0)
    x.gpuMHz = 400
    x.gpuBusy = 0.9
    x.gpuThermalCapped = false
    #expect(EventBuilder.clockDrop(x, peaks: peaks, busyThreshold: 0.6) == 0)
    x.gpuThermalCapped = true
    #expect(EventBuilder.clockDrop(x, peaks: peaks, busyThreshold: 0.6) == 0.75)
}


@Test func tokenComparisonNeedsFiveReadingsEachSide() throws {
    // One reading just before the event (a reply's first second) is no baseline.
    var b = EventBuilder()
    _ = b.feed(s(0, throttled: false, tps: 15), peaks: peaks)
    for i in 1...20 { _ = b.feed(s(Double(i), throttled: true, perf: 3000, tps: 100), peaks: peaks) }
    let flushed = b.flush()
    let e = try #require(flushed)
    #expect(e.tokensBefore == nil)
    #expect(e.tokensDuring == 100)
    #expect(Format.tokenChange(before: e.tokensBefore, during: e.tokensDuring) == nil)
}
