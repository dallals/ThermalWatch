import Foundation
import Testing
@testable import ThermalCore

private func tempPath() -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("history.sqlite").path
}

private func full(_ t: Double) -> Sample {
    var s = Sample(timestamp: t, pressure: 1)
    s.superMHz = 4500; s.perfMHz = 4200; s.gpuMHz = 1500
    s.superBusy = 0.7; s.perfBusy = 0.65; s.gpuBusy = 0.2
    s.gpuThermalCapped = false
    s.cpuWatts = 25.5; s.gpuWatts = 3.25; s.systemWatts = 38
    s.cpuTempC = 88.5; s.gpuTempC = 70
    s.fanRPM = [2400, 2380.5]
    s.tokensPerSec = 41.5
    s.state = .throttled
    s.clockLimited = true
    return s
}

@Test func samplesRoundTripWithNilsAndOrdering() throws {
    let store = try HistoryStore(path: tempPath())
    let empty = Sample(timestamp: 5)
    try store.insert([full(10), empty, full(20)])
    let back = try store.samples(from: 0, to: 100)
    #expect(back == [empty, full(10), full(20)])
    #expect(try store.samples(from: 10, to: 10) == [full(10)])
}

@Test func reopeningKeepsData() throws {
    let path = tempPath()
    try HistoryStore(path: path).insert([full(1)])
    #expect(try HistoryStore(path: path).samples(from: 0, to: 2).count == 1)
}

@Test func eventsOverlapQueryNewestFirst() throws {
    let store = try HistoryStore(path: tempPath())
    let a = ThrottleEvent(start: 100, end: 110, worstPressure: 1, maxClockDrop: 0.2, tokensBefore: 40, tokensDuring: 30)
    let b = ThrottleEvent(start: 200, end: 205, worstPressure: 2, maxClockDrop: 0, tokensBefore: nil, tokensDuring: nil)
    try store.insert(a)
    try store.insert(b)
    #expect(try store.events(from: 105, to: 300) == [b, a])
    #expect(try store.events(from: 111, to: 199).isEmpty)
}

@Test func pruneRemovesOldSamplesAndEventsButKeepsLoadTests() throws {
    let store = try HistoryStore(path: tempPath())
    try store.insert([full(10), full(1000)])
    try store.insert(ThrottleEvent(start: 5, end: 20, worstPressure: 1, maxClockDrop: 0, tokensBefore: nil, tokensDuring: nil))
    _ = try store.insert(LoadTestResult(id: nil, startedAt: 1, kind: .cpu, plannedSeconds: 300, ranSeconds: 300, secondsToThrottle: nil, steadyDrop: [:], peakCPUTempC: nil, peakGPUTempC: nil, startWatts: nil, endWatts: nil, stopReason: .finished, note: ""))
    try store.prune(olderThan: 500)
    #expect(try store.samples(from: 0, to: 2000).map(\.timestamp) == [1000])
    #expect(try store.events(from: 0, to: 2000).isEmpty)
    #expect(try store.loadTests().count == 1)
}

@Test func maxBusyMHzIgnoresIdleAndOld() throws {
    let store = try HistoryStore(path: tempPath())
    var idle = full(50); idle.perfMHz = 4380; idle.perfBusy = 0.3
    var old = full(1); old.superMHz = 4608
    try store.insert([full(40), idle, old])
    let peaks = try store.maxBusyMHz(since: 10, busyAbove: 0.6)
    #expect(peaks == [.superCores: 4500, .performance: 4200])
}

@Test func throttledSecondsCountsThrottledSamples() throws {
    let store = try HistoryStore(path: tempPath())
    try store.insert([full(1), full(2), Sample(timestamp: 3), full(4)])
    #expect(try store.throttledSeconds(from: 0, to: 3) == 2)
}

@Test func loadTestsRoundTripNewestFirst() throws {
    let store = try HistoryStore(path: tempPath())
    let r1 = LoadTestResult(id: nil, startedAt: 100, kind: .both, plannedSeconds: 300, ranSeconds: 120, secondsToThrottle: 42, steadyDrop: ["perf": 0.18], peakCPUTempC: 104, peakGPUTempC: 88, startWatts: 90, endWatts: 60, stopReason: .userStopped, note: "desk")
    let r2 = LoadTestResult(id: nil, startedAt: 200, kind: .gpu, plannedSeconds: 600, ranSeconds: 600, secondsToThrottle: nil, steadyDrop: [:], peakCPUTempC: nil, peakGPUTempC: 70, startWatts: 30, endWatts: 30, stopReason: .finished, note: "")
    let id1 = try store.insert(r1)
    let id2 = try store.insert(r2)
    let back = try store.loadTests()
    #expect(back.map(\.id) == [id2, id1])
    var expected = r1; expected.id = id1
    #expect(back[1] == expected)
}

@Test func badPathThrows() {
    #expect(throws: StoreError.self) { try HistoryStore(path: "/nonexistent-dir-\(UUID().uuidString)/h.sqlite") }
}

@Test func concurrentCallsAreAtomic() async throws {
    let store = try HistoryStore(path: tempPath())
    let batches = 20, perBatch = 5
    let ids = try await withThrowingTaskGroup(of: Int64?.self) { group in
        for b in 0..<batches {
            group.addTask {
                let base = Double(1000 + b * perBatch)
                try store.insert((0..<perBatch).map { full(base + Double($0)) })
                try store.prune(olderThan: 0)
                _ = try store.samples(from: 0, to: 100_000)
                _ = try store.throttledSeconds(from: 0, to: 100_000)
                return nil
            }
            group.addTask {
                try store.insert(LoadTestResult(id: nil, startedAt: Double(b), kind: .cpu, plannedSeconds: 1, ranSeconds: 1, secondsToThrottle: nil, steadyDrop: [:], peakCPUTempC: nil, peakGPUTempC: nil, startWatts: nil, endWatts: nil, stopReason: .finished, note: ""))
            }
        }
        var out: [Int64] = []
        for try await id in group { if let id { out.append(id) } }
        return out
    }
    #expect(Set(ids).count == batches)
    #expect(try store.samples(from: 0, to: 100_000).count == batches * perBatch)
    #expect(try store.loadTests().count == batches)
}
