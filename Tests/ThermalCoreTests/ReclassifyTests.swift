import Foundation
import Testing
@testable import ThermalCore

private func gpu(_ t: Double, mhz: Double, capped: Bool, oldState: ThrottleState = .throttled) -> Sample {
    var s = Sample(timestamp: t, pressure: 0)
    s.gpuMHz = mhz
    s.gpuBusy = 0.9
    s.gpuThermalCapped = capped
    s.state = oldState          // what the old rules recorded
    s.clockLimited = oldState == .throttled
    return s
}

@Test func gpuAtFloorWithoutCapIsNoLongerAnEvent() {
    let samples = (0..<12).map { gpu(Double($0), mhz: 338, capped: false) }
    let r = Reclassify.run(samples, tableMax: [.gpu: 1620])
    #expect(r.samples.allSatisfy { $0.state == .cool && !$0.clockLimited })
    #expect(r.events.isEmpty)
}

@Test func thermallyCappedStretchBecomesOneEventWithRealDrop() throws {
    let samples = (0..<12).map { gpu(Double($0), mhz: 567, capped: true, oldState: .cool) }
    let r = Reclassify.run(samples, tableMax: [.gpu: 1620])
    #expect(r.samples.allSatisfy { $0.state == .throttled && $0.clockLimited })
    let e = try #require(r.events.first)
    #expect(r.events.count == 1)
    #expect(e.start == 0 && e.end == 11)
    #expect(abs(e.maxClockDrop - 0.65) < 1e-9)
}

@Test func reclassifiedHistoryRoundTripsThroughTheStore() throws {
    let path = NSTemporaryDirectory() + "reclassify-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try HistoryStore(path: path)
    let old = (0..<12).map { gpu(Double($0), mhz: 338, capped: false) }
    try store.insert(old)
    try store.insert(ThrottleEvent(start: 0, end: 11, worstPressure: 0, maxClockDrop: 0.79, tokensBefore: nil, tokensDuring: nil))

    let r = Reclassify.run(try store.samples(from: 0, to: 100), tableMax: [.gpu: 1620])
    try store.replaceClassification(samples: r.samples, events: r.events)

    #expect(try store.events(from: 0, to: 100).isEmpty)
    #expect(try store.samples(from: 0, to: 100).allSatisfy { $0.state == .cool && !$0.clockLimited })
}
