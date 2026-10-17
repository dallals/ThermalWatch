import Testing
@testable import ThermalCore

private func s(_ t: Double, perf: Double = 4000, gpu: Double = 1600, cpuT: Double = 80, gpuT: Double = 70,
               cpuW: Double? = 40, gpuW: Double? = 20, throttled: Bool = false) -> Sample {
    var x = Sample(timestamp: t, pressure: throttled ? 1 : 0)
    x.perfMHz = perf; x.perfBusy = 1
    x.superMHz = 4400; x.superBusy = 1
    x.gpuMHz = gpu; x.gpuBusy = 1
    x.cpuTempC = cpuT; x.gpuTempC = gpuT
    x.cpuWatts = cpuW; x.gpuWatts = gpuW
    x.state = throttled ? .throttled : .cool
    return x
}

@Test func finishesAtPlannedDuration() {
    var run = LoadTestRun(kind: .cpu, plannedSeconds: 10, startedAt: 100)
    #expect(run.feed(s(99)) == nil)          // before the start: ignored
    #expect(run.samples.isEmpty)
    for t in 100..<110 { #expect(run.feed(s(Double(t))) == nil) }
    #expect(run.feed(s(110)) == .finished)
    #expect(run.elapsed == 10)
}

@Test func stopsWhenTooHot() {
    var run = LoadTestRun(kind: .both, plannedSeconds: 600, startedAt: 0)
    #expect(run.feed(s(1, cpuT: 105)) == nil)
    #expect(run.feed(s(2, gpuT: 105.5)) == .tooHot)
}

@Test func resultSummarisesTheRun() {
    var run = LoadTestRun(kind: .cpu, plannedSeconds: 300, startedAt: 0)
    for t in 0..<100 {
        let late = t >= 40
        _ = run.feed(s(Double(t), perf: late ? 3000 : 4000, cpuT: late ? 101 : 85, cpuW: late ? 30 : 50, gpuW: nil, throttled: late))
    }
    let r = run.result(stopReason: .userStopped, endedAt: 99, peaks: [.performance: 4000, .superCores: 4400, .gpu: 1600], note: "desk")
    #expect(r.secondsToThrottle == 40)
    #expect(r.steadyDrop == ["perf": 0.25, "super": 0])
    #expect(r.peakCPUTempC == 101)
    #expect(r.startWatts == 50)
    #expect(r.endWatts == 30)
    #expect(r.ranSeconds == 99)
    #expect(r.stopReason == .userStopped)
    #expect(r.note == "desk")
    #expect(r.kind == .cpu)
}

@Test func runThatNeverThrottles() {
    var run = LoadTestRun(kind: .gpu, plannedSeconds: 5, startedAt: 0)
    for t in 0...5 { _ = run.feed(s(Double(t))) }
    let r = run.result(stopReason: .finished, endedAt: 5, peaks: [.gpu: 1600], note: "")
    #expect(r.secondsToThrottle == nil)
    #expect(r.steadyDrop == ["gpu": 0])
}
