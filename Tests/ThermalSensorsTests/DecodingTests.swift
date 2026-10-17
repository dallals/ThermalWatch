import Foundation
import Testing
@testable import ThermalSensors

private func st(_ pairs: [(String, Int64)]) -> [StateResidency] {
    pairs.map { StateResidency(name: $0.0, ticks: $0.1) }
}

@Test func tableIndexParsesStateNames() {
    #expect(Residency.tableIndex("V12P7") == 12)
    #expect(Residency.tableIndex("V0P19") == 0)
    #expect(Residency.tableIndex("P3") == 3)
    #expect(Residency.tableIndex("IDLE") == nil)
    #expect(Residency.tableIndex("DOWN") == nil)
    #expect(Residency.tableIndex("OFF") == nil)
    #expect(Residency.tableIndex("NO_CLTM") == nil)
    #expect(Residency.tableIndex("NON_IDLE") == nil)
}

@Test func summarizeWeightsFrequencyByResidency() throws {
    let s = try #require(Residency.summarize(st([("IDLE", 50), ("V0P2", 25), ("V2P0", 25)]), table: [1000, 2000, 3000]))
    #expect(s.activeFraction == 0.5)
    #expect(s.averageMHz == 2000)
}

@Test func summarizeClampsIndexPastTableEnd() throws {
    let s = try #require(Residency.summarize(st([("P5", 10)]), table: [100, 200]))
    #expect(s.averageMHz == 200)
    #expect(s.activeFraction == 1)
}

@Test func poweredDownClusterHasNoFrequency() throws {
    let s = try #require(Residency.summarize(st([("DOWN", 100), ("IDLE", 0), ("V3P1", 0)]), table: [1000, 2000, 3000, 4000]))
    #expect(s.activeFraction == 0)
    #expect(s.averageMHz == nil)
}

@Test func emptyTableGivesNoFrequency() throws {
    let s = try #require(Residency.summarize(st([("V1P0", 100)]), table: []))
    #expect(s.activeFraction == 1)
    #expect(s.averageMHz == nil)
}

@Test func summarizeNeedsTicks() {
    #expect(Residency.summarize([], table: [1]) == nil)
    #expect(Residency.summarize(st([("IDLE", 0)]), table: [1]) == nil)
}

@Test func mergeSumsTicksByNameKeepingOrder() {
    let merged = Residency.merge([st([("DOWN", 100), ("V1P0", 0)]), st([("DOWN", 0), ("V1P0", 50), ("IDLE", 5)])])
    #expect(merged == st([("DOWN", 100), ("V1P0", 50), ("IDLE", 5)]))
}

@Test func thermalCapDetectsAnyPState() {
    #expect(Residency.thermalCapped(st([("NO_CLTM", 100), ("P1", 0)])) == false)
    #expect(Residency.thermalCapped(st([("NO_CLTM", 90), ("P4", 10)])) == true)
    #expect(Residency.thermalCapped(st([("OFF", 100)])) == false)
}

@Test func frequencyTableDecodesLittleEndianPairs() {
    var data = Data()
    for v: UInt32 in [1_308_000, 900, 4_608_000, 1100] {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(0xFF) // trailing partial entry is ignored
    #expect(FrequencyTable.decode(data, divisor: 1_000) == [1308, 4608])
}

@Test func smcValueDecoding() {
    let bits = Float(54.5).bitPattern
    let flt: [UInt8] = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
    #expect(SMCValue.decode(type: "flt ", bytes: flt) == 54.5)
    #expect(SMCValue.decode(type: "flt ", bytes: [1, 2]) == nil)
    #expect(SMCValue.decode(type: "ui8 ", bytes: [2]) == 2)
    #expect(SMCValue.decode(type: "ui16", bytes: [0x1E, 0x92]) == 7826)
    #expect(SMCValue.decode(type: "ui32", bytes: [0, 0, 0x0F, 0x18]) == 3864)
    #expect(SMCValue.decode(type: "sp78", bytes: [0x28, 0x80]) == 40.5)
    #expect(SMCValue.decode(type: "fpe2", bytes: [0x25, 0x80]) == 2400)
    #expect(SMCValue.decode(type: "ch8*", bytes: [65]) == nil)
}

@Test func fourCCRoundTrip() {
    #expect(SMCValue.fourCC("F0Ac") == 0x4630_4163)
    #expect(SMCValue.string(0x4630_4163) == "F0Ac")
}

@Test func hottestFiltersByPrefixAndRange() {
    let r: [String: Double] = ["Tp00": 54, "Tm01": 61, "Tg0a": 47, "Tp99": 140, "Tf06": 93]
    #expect(SMCKeys.hottest(r, where: SMCKeys.isCPUDie) == 61)
    #expect(SMCKeys.hottest(r, where: SMCKeys.isGPUDie) == 47)
    #expect(SMCKeys.hottest([:], where: SMCKeys.isGPUDie) == nil)
}

@Test func energyToWatts() {
    #expect(Energy.watts(value: 2_000_000_000, unit: "nJ", seconds: 2) == 1.0)
    #expect(Energy.watts(value: 1000, unit: "mJ", seconds: 1) == 1.0)
    #expect(Energy.watts(value: 5, unit: "bogus", seconds: 1) == nil)
    #expect(Energy.watts(value: 5, unit: "mJ", seconds: 0) == nil)
}

@Test func smcNonFiniteFloatIsNil() {
    let nan = Float.nan.bitPattern, inf = Float.infinity.bitPattern
    func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    #expect(SMCValue.decode(type: "flt ", bytes: le(nan)) == nil)
    #expect(SMCValue.decode(type: "flt ", bytes: le(inf)) == nil)
}

@Test func negativeResidencyIndexIsNil() {
    #expect(Residency.tableIndex("P-1") == nil)
    #expect(Residency.tableIndex("V-2P3") == nil)
    #expect(Residency.tableIndex("P3") == 3)
}
