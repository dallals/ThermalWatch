import Testing
@testable import ThermalCore

private let peaks: [Cluster: Double] = [.performance: 4000]

private func perf(_ t: Double, mhz: Double, busy: Double = 0.9, pressure: Int = 0) -> Sample {
    var s = Sample(timestamp: t, pressure: pressure)
    s.perfMHz = mhz
    s.perfBusy = busy
    return s
}

/// Classifies `samples` in order, feeding each earlier sample as `recent`.
private func run(_ samples: [Sample], peaks: [Cluster: Double] = peaks) -> [Classification] {
    let d = ThrottleDetector()
    var recent: [Sample] = []
    var out: [Classification] = []
    for s in samples {
        out.append(d.classify(current: s, recent: recent, peaks: peaks))
        recent.append(s)
    }
    return out
}

@Test func moderatePressureIsThrottled() {
    let c = run([perf(0, mhz: 4000, busy: 0.1, pressure: 1)])[0]
    #expect(c == Classification(state: .throttled, clockLimited: false))
}

@Test func sleepingPressureIsThrottled() {
    #expect(run([perf(0, mhz: 4000, busy: 0.1, pressure: 4)])[0].state == .throttled)
}

@Test func clockLimitedAfterFiveBusySeconds() {
    let out = run((0..<5).map { perf(Double($0), mhz: 3300) })
    #expect(out[3] == Classification(state: .warm, clockLimited: false))
    #expect(out[4] == Classification(state: .throttled, clockLimited: true))
}

@Test func lowClockWhileNotBusyIsCool() {
    let out = run((0..<6).map { perf(Double($0), mhz: 1500, busy: 0.5) })
    #expect(out.allSatisfy { $0 == Classification(state: .cool, clockLimited: false) })
}

@Test func smallDropIsWarm() {
    let out = run((0..<6).map { perf(Double($0), mhz: 3500) })
    #expect(out[5] == Classification(state: .warm, clockLimited: false))
}

@Test func tinyDropIsCool() {
    #expect(run([perf(0, mhz: 3900)])[0].state == .cool)
}

@Test func hotDieIsWarm() {
    var hot = Sample(timestamp: 0); hot.cpuTempC = 96
    var fine = Sample(timestamp: 0); fine.gpuTempC = 95
    #expect(run([hot])[0].state == .warm)
    #expect(run([fine])[0].state == .cool)
}

@Test func gapBreaksBusyRun() {
    let samples = [0.0, 1, 2, 30, 31, 32].map { perf($0, mhz: 3300) }
    let out = run(samples)
    #expect(out[5].clockLimited == false)
    #expect(out[5].state == .warm)
}

@Test func gpuThermalCapIsClockLimited() {
    #expect(run([gpu(0, mhz: 562, capped: true)], peaks: [.gpu: 1620])[0] == Classification(state: .throttled, clockLimited: true))
}

@Test func gpuCapFlagAtFullSpeedIsNotClockLimited() {
    // The cap flag flickers on for a second while the GPU still runs at ~99% of peak.
    #expect(run([gpu(0, mhz: 1604, capped: true)], peaks: [.gpu: 1620])[0] == Classification(state: .cool, clockLimited: false))
}

@Test func gpuCapFlagWhileGPUWindsDownIsNotClockLimited() {
    var s = gpu(0, mhz: 1480, capped: true)
    s.gpuBusy = 0.32
    #expect(run([s], peaks: [.gpu: 1620])[0] == Classification(state: .cool, clockLimited: false))
}

@Test func emptyPeaksNeverClockLimited() {
    let out = run((0..<8).map { perf(Double($0), mhz: 100) }, peaks: [:])
    #expect(out.allSatisfy { $0 == Classification(state: .cool, clockLimited: false) })
}

@Test func peakTrackerPrefersObservedBusyPeak() {
    var p = PeakTracker(tableMax: [.performance: 4380, .gpu: 1620])
    #expect(p.peaks() == [.performance: 4380, .gpu: 1620])
    p.observe(perf(0, mhz: 4100))
    p.observe(perf(1, mhz: 4300, busy: 0.3)) // not busy: ignored
    #expect(p.peaks()[.performance] == 4100)
    #expect(p.peaks()[.gpu] == 1620)
    p.replaceObserved([.gpu: 1500])
    #expect(p.peaks() == [.performance: 4380, .gpu: 1500])
}

private func gpu(_ t: Double, mhz: Double, capped: Bool) -> Sample {
    var s = Sample(timestamp: t, pressure: 0)
    s.gpuMHz = mhz
    s.gpuBusy = 0.9
    s.gpuThermalCapped = capped
    return s
}

@Test func lowGPUClockWithoutThermalCapIsCool() {
    // The GPU idles at its lowest state between bursts of an LLM reply while still counted as busy.
    let out = run((0..<8).map { gpu(Double($0), mhz: 338, capped: false) }, peaks: [.gpu: 1620])
    #expect(out.allSatisfy { $0 == Classification(state: .cool, clockLimited: false) })
}

@Test func lowGPUClockWithThermalCapIsClockLimited() {
    let out = run((0..<8).map { gpu(Double($0), mhz: 562, capped: true) }, peaks: [.gpu: 1620])
    #expect(out.allSatisfy { $0 == Classification(state: .throttled, clockLimited: true) })
}
