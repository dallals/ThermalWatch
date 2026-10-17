import Testing
@testable import ThermalCore

private func sample(_ t: Double, perf: Double? = nil, state: ThrottleState = .cool, pressure: Int = 0, limited: Bool = false) -> Sample {
    var s = Sample(timestamp: t, pressure: pressure)
    s.perfMHz = perf
    s.state = state
    s.clockLimited = limited
    return s
}

@Test func seriesBucketsMinMaxMean() {
    let samples = [sample(0, perf: 10), sample(1, perf: 30), sample(2, perf: nil), sample(30, perf: 5)]
    let pts = Downsampler.series(samples, bucket: 30) { $0.perfMHz }
    #expect(pts == [SeriesPoint(t: 0, min: 10, max: 30, mean: 20), SeriesPoint(t: 30, min: 5, max: 5, mean: 5)])
    #expect(Downsampler.series(samples, bucket: 0) { $0.perfMHz }.isEmpty)
}

@Test func bandsMergeConsecutiveThrottledSamples() {
    let samples = [
        sample(0, state: .throttled, pressure: 1),
        sample(1, state: .throttled, pressure: 1),
        sample(2, state: .cool),
        sample(3, state: .throttled, pressure: 1),
        sample(4, state: .throttled, pressure: 2),
        sample(10, state: .throttled, pressure: 2),
        sample(11, state: .throttled, pressure: 2, limited: true),
    ]
    #expect(Downsampler.bands(samples) == [
        StateBand(start: 0, end: 2, pressure: 1, clockLimited: false),
        StateBand(start: 3, end: 4, pressure: 1, clockLimited: false),
        StateBand(start: 4, end: 5, pressure: 2, clockLimited: false),
        StateBand(start: 10, end: 11, pressure: 2, clockLimited: false),
        StateBand(start: 11, end: 12, pressure: 2, clockLimited: true),
    ])
}

@Test func timeRangeBuckets() {
    #expect(TimeRange.tenMinutes.bucketSeconds == 1)
    #expect(TimeRange.week.bucketSeconds == 600)
    #expect(TimeRange.day.label == "24 h")
}

@Test func csvRows() {
    var s = Sample(timestamp: 1_700_000_000, pressure: 1)
    s.perfMHz = 4200
    s.perfBusy = 0.6512
    s.gpuThermalCapped = true
    s.fanRPM = [2400, 2380.4]
    s.state = .throttled
    let csv = CSVExport.csv([s, Sample(timestamp: 1_700_000_001)])
    let lines = csv.split(separator: "\n").map(String.init)
    #expect(lines[0] == CSVExport.header)
    #expect(lines[1] == "2023-11-14T22:13:20Z,1,,4200.0,,,0.651,,1,,,,,,2400;2380,,2,0")
    #expect(lines[2] == "2023-11-14T22:13:21Z,,,,,,,,,,,,,,,,0,0")
    #expect(csv.hasSuffix("\n"))
}

@Test func formatting() {
    #expect(Format.ghz(4420) == "4.42 GHz")
    #expect(Format.ghz(nil) == "—")
    #expect(Format.percent(0.913) == "91%")
    #expect(Format.temp(78.4) == "78°")
    #expect(Format.watts(41.6) == "42 W")
    #expect(Format.grouped(999) == "999")
    #expect(Format.grouped(2400) == "2,400")
    #expect(Format.grouped(1_234_567) == "1,234,567")
    #expect(Format.rpm([2400, 2380]) == "2,400 rpm")
    #expect(Format.rpm([]) == "—")
    #expect(Format.tokens(38.2) == "38 tok/s")
    #expect(Format.tokens(nil) == "idle")
    #expect(Format.duration(0) == "0s")
    #expect(Format.duration(45) == "45s")
    #expect(Format.duration(185) == "3m 05s")
    #expect(Format.duration(3720) == "1h 02m")
    #expect(Format.tokenChange(before: 41, during: 29) == "41 → 29 tok/s, −29%")
    #expect(Format.tokenChange(before: 30, during: 33) == "30 → 33 tok/s, +10%")
    #expect(Format.tokenChange(before: nil, during: 29) == nil)
}

@Test func nonFiniteFormatsFallBack() {
    #expect(Format.watts(.nan) == "—")
    #expect(Format.rpm([.infinity]) == "—")
    #expect(Format.duration(.nan) == "0s")
    #expect(Format.tokenChange(before: .nan, during: 30) == nil)
    #expect(Format.ghz(.infinity) == "—")
    #expect(Format.percent(.nan) == "—")
    #expect(Format.temp(.nan) == "—")
    #expect(Format.tokens(.nan) == "idle")
}

@Test func csvNonFiniteCellsAreEmpty() {
    var s = Sample(timestamp: 0)
    s.cpuWatts = .nan
    s.fanRPM = [.infinity, 2000]
    let row = CSVExport.csv([s]).split(separator: "\n", omittingEmptySubsequences: false)[1].split(separator: ",", omittingEmptySubsequences: false)
    #expect(row[9] == "")
    #expect(row[14] == "2000")
}
