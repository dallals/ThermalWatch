import Foundation
import Testing
@testable import ThermalCore

@Test func sampleAccessorsMapClusters() {
    var s = Sample(timestamp: 10)
    s.superMHz = 4000; s.perfMHz = 3500; s.gpuMHz = 1500
    s.superBusy = 0.9; s.perfBusy = 0.5; s.gpuBusy = 0.1
    #expect(s.mhz(.superCores) == 4000)
    #expect(s.mhz(.performance) == 3500)
    #expect(s.mhz(.gpu) == 1500)
    #expect(s.busy(.superCores) == 0.9)
    #expect(s.busy(.performance) == 0.5)
    #expect(s.busy(.gpu) == 0.1)
}

@Test func sampleDefaultsAreEmpty() {
    let s = Sample(timestamp: 5)
    #expect(s.pressure == nil)
    #expect(s.fanRPM.isEmpty)
    #expect(s.state == .cool)
    #expect(s.clockLimited == false)
}

@Test func sampleRoundTripsThroughJSON() throws {
    var s = Sample(timestamp: 1_700_000_000.5, pressure: 2)
    s.fanRPM = [2400, 2380]
    s.state = .throttled
    s.clockLimited = true
    s.gpuThermalCapped = true
    s.tokensPerSec = 38.5
    let data = try JSONEncoder().encode(s)
    #expect(try JSONDecoder().decode(Sample.self, from: data) == s)
}

@Test func labels() {
    #expect(PressureLevel(rawValue: 0)?.label == "Nominal")
    #expect(PressureLevel(rawValue: 3)?.label == "Trapping")
    #expect(PressureLevel(rawValue: 9) == nil)
    #expect(Cluster.performance.label == "Perf")
    #expect(ThrottleState.throttled.label == "THROTTLED")
    #expect(ThrottleState.warm > ThrottleState.cool)
}
