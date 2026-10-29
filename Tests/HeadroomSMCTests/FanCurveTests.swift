import Foundation
@testable import HeadroomSMC
import Testing

@Test func curveIsStraightBetweenMinAndMax() {
    let curve = FanCurve(minTemp: 50, maxTemp: 80)
    #expect(curve.level(at: 40) == 0)
    #expect(curve.level(at: 50) == 0)
    #expect(curve.level(at: 65) == 0.5)
    #expect(curve.level(at: 80) == 1)
    #expect(curve.level(at: 99) == 1)
}

@Test func invalidCurveRunsFlatOut() {
    #expect(!FanCurve(minTemp: 80, maxTemp: 80).isValid)
    #expect(FanCurve(minTemp: 80, maxTemp: 60).level(at: 30) == 1)
}

@Test func governorLeavesCoolMacToMacOS() {
    var g = FanGovernor(curve: FanCurve(minTemp: 50, maxTemp: 80))
    #expect(g.tick(temperature: 45) == nil)
    #expect(g.tick(temperature: 49.9) == nil)
    #expect(g.tick(temperature: 50) == 0)
}

@Test func governorRisesAtOnceAndFallsGently() {
    var g = FanGovernor(curve: FanCurve(minTemp: 50, maxTemp: 80))
    #expect(g.tick(temperature: 80) == 1)
    let next = g.tick(temperature: 50)!
    #expect(abs(next - 0.96) < 1e-9)
    #expect(g.tick(temperature: 95) == 1)
}

@Test func governorReleasesBelowTheMarginOnlyOnceAtLowestSpeed() {
    var g = FanGovernor(curve: FanCurve(minTemp: 50, maxTemp: 80))
    _ = g.tick(temperature: 53)  // 0.1
    #expect(g.tick(temperature: 40)! > 0)  // still ramping down
    var level = g.level
    while let l = level, l > 0 { level = g.tick(temperature: 40) }
    #expect(g.tick(temperature: 40) == nil)
    #expect(g.level == nil)
    // Just under the min but within the margin: holds the lowest speed.
    var h = FanGovernor(curve: FanCurve(minTemp: 50, maxTemp: 80))
    _ = h.tick(temperature: 50)
    #expect(h.tick(temperature: 48) == 0)
}

@Test func governorRunsFlatOutWithoutAReading() {
    var g = FanGovernor(curve: FanCurve(minTemp: 50, maxTemp: 80))
    #expect(g.tick(temperature: nil) == 1)
}

@Test func keysRoundTrip() {
    #expect(SMC.Key("F0Ac").description == "F0Ac")
    #expect(SMC.Key("#KEY").code == 0x234B_4559)
}

@Test func valuesRoundTrip() {
    let flt = SMC.Key("flt ")
    let bytes = SMC.encode(3371, type: flt, size: 4)!
    #expect(bytes == [0, 176, 82, 69])  // as read from F0Ac on an M4 Pro
    #expect(SMC.decode(bytes, type: flt) == 3371)
    #expect(SMC.encode(1, type: "ui8 ", size: 1) == [1])
    #expect(SMC.decode([0, 0, 6, 192], type: "ui32") == 1728)
    #expect(SMC.decode([0x5A, 0x80], type: "sp78") == 90.5)
}

@Test func sensorsCombineTheirOwnCores() {
    let readings: [SMC.Key: Double] = ["Tp01": 90, "Te05": 60, "Tg0f": 50, "Tg1d": 70, "Tp0z": 0, "TB0T": 40]
    #expect(FanSensor.chipAverage.temperature(readings) == 67.5)  // the unused 0 °C core is ignored
    #expect(FanSensor.cpuAverage.temperature(readings) == 75)
    #expect(FanSensor.gpuAverage.temperature(readings) == 60)
    #expect(FanSensor.hottest.temperature(readings) == 90)
    #expect(FanSensor.gpuAverage.temperature(["Tp01": 90]) == nil)
}

// M1–M3: after `Ftst` is set, the mode write answers 0x82 until thermalmonitord lets go.
@Test func takeoverWaitsOutBusySMC() throws {
    var clock = Date(timeIntervalSince1970: 0)
    var attempts = 0
    try Thermals.retrying(for: 6, now: { clock }, sleep: { clock += $0 }) { () throws(SMC.Failure) in
        attempts += 1
        if attempts < 25 { throw .result(0x82) }
    }
    #expect(attempts == 25)
}

@Test func takeoverGivesUpAfterTimeout() {
    var clock = Date(timeIntervalSince1970: 0)
    var attempts = 0
    #expect(throws: SMC.Failure.result(0x82)) {
        try Thermals.retrying(for: 1, now: { clock }, sleep: { clock += $0 }) { () throws(SMC.Failure) in
            attempts += 1
            throw .result(0x82)
        }
    }
    #expect(attempts == 11)
}

@Test func takeoverDoesNotRetryOtherFailures() {
    var attempts = 0
    #expect(throws: SMC.Failure.result(0x86)) {
        try Thermals.retrying(for: 6, sleep: { _ in }) { () throws(SMC.Failure) in
            attempts += 1
            throw .result(0x86)
        }
    }
    #expect(attempts == 1)
}

@Test func noUnlockMeansNoRetry() {
    var attempts = 0
    #expect(throws: SMC.Failure.result(0x82)) {
        try Thermals.retrying(for: 0, sleep: { _ in }) { () throws(SMC.Failure) in
            attempts += 1
            throw .result(0x82)
        }
    }
    #expect(attempts == 1)
}
