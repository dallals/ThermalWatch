import Testing
@testable import ThermalCore

private func p(_ t: Double, pressure: Int = 0, limited: Bool = false) -> Sample {
    var s = Sample(timestamp: t, pressure: pressure)
    s.clockLimited = limited
    s.state = (pressure >= 1 || limited) ? .throttled : .cool
    return s
}

@Test func heavyAlertsOnceOnEntry() {
    var a = AlertPolicy()
    #expect(a.evaluate(p(0, pressure: 2)) == .heavyPressure)
    #expect(a.evaluate(p(1, pressure: 3)) == nil)
    #expect(a.evaluate(p(2, pressure: 0)) == nil)
    #expect(a.evaluate(p(300, pressure: 2)) == nil)   // within 10 minutes of the last alert
    #expect(a.evaluate(p(301, pressure: 0)) == nil)
    #expect(a.evaluate(p(700, pressure: 2)) == .heavyPressure)
}

@Test func sustainedAlertAtThirtySeconds() {
    var a = AlertPolicy()
    for t in 0..<29 { #expect(a.evaluate(p(Double(t), pressure: 1, limited: true)) == nil) }
    #expect(a.evaluate(p(29, pressure: 1, limited: true)) == .sustainedClockLimit)
    #expect(a.evaluate(p(30, pressure: 1, limited: true)) == nil)
}

@Test func disabledAlertsNeverFire() {
    var a = AlertPolicy()
    a.heavyEnabled = false
    a.sustainedEnabled = false
    #expect(a.evaluate(p(0, pressure: 2)) == nil)
    for t in 1...40 { #expect(a.evaluate(p(Double(t), limited: true)) == nil) }
}

@Test func alertText() {
    var s = p(0, pressure: 2)
    s.cpuTempC = 98.4
    s.gpuTempC = 80
    #expect(AlertText.title(.heavyPressure) == "Chip is throttling")
    #expect(AlertText.body(kind: .heavyPressure, sample: s, peaks: [:]) == "Thermal pressure is Heavy. CPU 98°C, GPU 80°C.")

    var l = p(0, limited: true)
    l.perfMHz = 3120; l.perfBusy = 0.95
    #expect(AlertText.title(.sustainedClockLimit) == "Clocks held down")
    #expect(AlertText.body(kind: .sustainedClockLimit, sample: l, peaks: [.performance: 4000]) == "Clocks held down for 30 s. Perf at 78% of peak.")

    var g = p(0, limited: true)
    g.gpuThermalCapped = true
    #expect(AlertText.body(kind: .sustainedClockLimit, sample: g, peaks: [:]) == "Clocks held down for 30 s. GPU thermally capped.")
}

@Test func alertTextIgnoresIdleClusters() {
    var g = p(0, limited: true)
    g.gpuThermalCapped = true
    g.perfMHz = 1200
    g.perfBusy = 0.1
    #expect(AlertText.body(kind: .sustainedClockLimit, sample: g, peaks: [.performance: 4000]) == "Clocks held down for 30 s. GPU thermally capped.")
}

@Test func iconColors() {
    #expect(IconStatus.from(nil) == IconStatus(color: .gray, slashed: false))
    #expect(IconStatus.from(p(0)) == IconStatus(color: .green, slashed: false))
    var warm = p(0); warm.state = .warm
    #expect(IconStatus.from(warm) == IconStatus(color: .yellow, slashed: false))
    #expect(IconStatus.from(p(0, pressure: 1)) == IconStatus(color: .yellow, slashed: false))
    #expect(IconStatus.from(p(0, pressure: 2)) == IconStatus(color: .orange, slashed: false))
    #expect(IconStatus.from(p(0, limited: true)) == IconStatus(color: .orange, slashed: true))
    #expect(IconStatus.from(p(0, pressure: 3, limited: true)) == IconStatus(color: .red, slashed: true))
    #expect(IconStatus.from(p(0, pressure: 4)) == IconStatus(color: .red, slashed: false))
}

@Test func sustainedTextNamesRealCause() {
    var a = p(0, limited: true)
    a.superMHz = 4010; a.superBusy = 1.0
    a.perfMHz = 4380; a.perfBusy = 1.0
    a.gpuThermalCapped = true
    let peaks: [Cluster: Double] = [.superCores: 4608, .performance: 4380]
    #expect(AlertText.body(kind: .sustainedClockLimit, sample: a, peaks: peaks) == "Clocks held down for 30 s. GPU thermally capped.")

    var c = p(0, limited: true)
    c.perfMHz = 3120; c.perfBusy = 0.95
    c.gpuThermalCapped = true
    #expect(AlertText.body(kind: .sustainedClockLimit, sample: c, peaks: [.performance: 4000]) == "Clocks held down for 30 s. Perf at 78% of peak. GPU thermally capped.")
}

@Test func heavyPendingDeliveredAfterInterval() {
    var a = AlertPolicy()
    for t in 0..<29 { _ = a.evaluate(p(Double(t), pressure: 1, limited: true)) }
    #expect(a.evaluate(p(29, pressure: 1, limited: true)) == .sustainedClockLimit)
    #expect(a.evaluate(p(170, pressure: 2)) == nil)
    #expect(a.evaluate(p(400, pressure: 2)) == nil)
    #expect(a.evaluate(p(629, pressure: 2)) == .heavyPressure)
    #expect(a.evaluate(p(630, pressure: 2)) == nil)
}

@Test func heavyPendingDroppedWhenPressureEases() {
    var a = AlertPolicy()
    for t in 0..<29 { _ = a.evaluate(p(Double(t), pressure: 1, limited: true)) }
    #expect(a.evaluate(p(29, pressure: 1, limited: true)) == .sustainedClockLimit)
    #expect(a.evaluate(p(170, pressure: 2)) == nil)
    #expect(a.evaluate(p(300, pressure: 1)) == nil)
    #expect(a.evaluate(p(629, pressure: 1)) == nil)
    #expect(a.evaluate(p(700, pressure: 0)) == nil)
}
