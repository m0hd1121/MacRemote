import XCTest
@testable import AlwaysOnCore

final class PowerPolicyTests: XCTestCase {
    private func evaluate(_ inputs: PolicyInputs, _ settings: PowerSettings = PowerSettings(),
                          memory: inout PolicyMemory) -> PolicyDecision {
        PowerPolicy.evaluate(inputs, settings: settings, memory: &memory)
    }

    func testACHoldsIdleAndSystemAssertions() {
        var memory = PolicyMemory()
        let d = evaluate(PolicyInputs(source: .ac, batteryPercent: 80), memory: &memory)
        XCTAssertEqual(d.mode, .fullAC)
        XCTAssertTrue(d.preventIdleSleep)
        XCTAssertTrue(d.preventSystemSleep)
        XCTAssertFalse(d.lidClosedOverride, "lid override is opt-in")
        XCTAssertEqual(Set(d.allowedPriorities), Set(ServicePriority.allCases))
    }

    func testBatteryNeverRequestsSystemSleepAssertion() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.batteryMode = .alwaysOn
        let d = evaluate(PolicyInputs(source: .battery, batteryPercent: 90), settings, memory: &memory)
        XCTAssertEqual(d.mode, .fullBattery)
        XCTAssertTrue(d.preventIdleSleep)
        XCTAssertFalse(d.preventSystemSleep)
    }

    func testDisabledAlwaysOnHoldsNothing() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.alwaysOnEnabled = false
        let d = evaluate(PolicyInputs(source: .ac, batteryPercent: nil), settings, memory: &memory)
        XCTAssertEqual(d.mode, .off)
        XCTAssertFalse(d.preventIdleSleep)
        XCTAssertFalse(d.lidClosedOverride)
    }

    func testDisableBelowThresholdWithHysteresis() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.batteryMode = .disableBelowThreshold
        settings.batteryThresholdPercent = 30
        settings.hysteresisPercent = 5

        XCTAssertEqual(evaluate(PolicyInputs(source: .battery, batteryPercent: 30), settings, memory: &memory).mode, .fullBattery)
        let low = evaluate(PolicyInputs(source: .battery, batteryPercent: 29), settings, memory: &memory)
        XCTAssertEqual(low.mode, .relaxed)
        XCTAssertFalse(low.preventIdleSleep)
        XCTAssertEqual(low.allowedPriorities, [.essential])
        // Recovering to 32% is not enough (needs 35%).
        XCTAssertEqual(evaluate(PolicyInputs(source: .battery, batteryPercent: 32), settings, memory: &memory).mode, .relaxed)
        XCTAssertEqual(evaluate(PolicyInputs(source: .battery, batteryPercent: 35), settings, memory: &memory).mode, .fullBattery)
    }

    func testAlwaysOnModeStepsDownToBatterySaver() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.batteryMode = .alwaysOn
        settings.batteryThresholdPercent = 25
        let d = evaluate(PolicyInputs(source: .battery, batteryPercent: 20), settings, memory: &memory)
        XCTAssertEqual(d.mode, .batterySaver)
        XCTAssertTrue(d.preventIdleSleep, "Battery Saver keeps networking alive")
        XCTAssertEqual(d.allowedPriorities, [.essential])
        XCTAssertFalse(d.lidClosedOverride)
    }

    func testBatterySaverRelaxesBelowThreshold() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.batteryMode = .batterySaver
        XCTAssertEqual(evaluate(PolicyInputs(source: .battery, batteryPercent: 60), settings, memory: &memory).mode, .batterySaver)
        XCTAssertEqual(evaluate(PolicyInputs(source: .battery, batteryPercent: 10), settings, memory: &memory).mode, .relaxed)
    }

    func testDisableAtThresholdLatchesUntilAC() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.batteryMode = .disableAtThreshold
        settings.batteryThresholdPercent = 40
        XCTAssertEqual(evaluate(PolicyInputs(source: .battery, batteryPercent: 41), settings, memory: &memory).mode, .fullBattery)
        XCTAssertEqual(evaluate(PolicyInputs(source: .battery, batteryPercent: 40), settings, memory: &memory).mode, .relaxed)
        // Even if the reading bounces back up, stay off until AC.
        XCTAssertEqual(evaluate(PolicyInputs(source: .battery, batteryPercent: 60), settings, memory: &memory).mode, .relaxed)
        XCTAssertEqual(evaluate(PolicyInputs(source: .ac, batteryPercent: 60), settings, memory: &memory).mode, .fullAC)
        XCTAssertEqual(evaluate(PolicyInputs(source: .battery, batteryPercent: 60), settings, memory: &memory).mode, .fullBattery)
    }

    func testLidOverrideRequiresHelper() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.lidClosedOperation = true
        let without = evaluate(PolicyInputs(source: .ac, batteryPercent: nil, helperAvailable: false), settings, memory: &memory)
        XCTAssertFalse(without.lidClosedOverride)
        XCTAssertTrue(without.reasons.contains { $0.contains("helper is not installed") })
        let with = evaluate(PolicyInputs(source: .ac, batteryPercent: nil, helperAvailable: true), settings, memory: &memory)
        XCTAssertTrue(with.lidClosedOverride)
    }

    func testLidOverrideOnBatteryIsGuarded() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.batteryMode = .alwaysOn
        settings.lidClosedOperation = true
        settings.helperBatteryFloorPercent = 25
        settings.batteryThresholdPercent = 10

        XCTAssertFalse(evaluate(PolicyInputs(source: .battery, batteryPercent: 80, helperAvailable: true), settings, memory: &memory).lidClosedOverride,
                       "not allowed on battery unless opted in")
        settings.lidClosedOnBattery = true
        XCTAssertTrue(evaluate(PolicyInputs(source: .battery, batteryPercent: 80, helperAvailable: true), settings, memory: &memory).lidClosedOverride)
        XCTAssertFalse(evaluate(PolicyInputs(source: .battery, batteryPercent: 25, helperAvailable: true), settings, memory: &memory).lidClosedOverride)
        XCTAssertFalse(evaluate(PolicyInputs(source: .battery, batteryPercent: nil, helperAvailable: true), settings, memory: &memory).lidClosedOverride)
        XCTAssertFalse(evaluate(PolicyInputs(source: .battery, batteryPercent: 80, thermal: .serious, helperAvailable: true), settings, memory: &memory).lidClosedOverride)
    }

    func testCriticalThermalRelaxesEverything() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.lidClosedOperation = true
        let d = evaluate(PolicyInputs(source: .ac, batteryPercent: nil, thermal: .critical, helperAvailable: true), settings, memory: &memory)
        XCTAssertEqual(d.mode, .relaxed)
        XCTAssertFalse(d.preventIdleSleep)
        XCTAssertFalse(d.lidClosedOverride)
        XCTAssertEqual(d.allowedPriorities, [.essential])
    }

    func testSeriousThermalStopsIntensiveServices() {
        var memory = PolicyMemory()
        let d = evaluate(PolicyInputs(source: .ac, batteryPercent: nil, thermal: .serious), memory: &memory)
        XCTAssertEqual(d.mode, .fullAC)
        XCTAssertFalse(d.allows(.intensive))
        XCTAssertTrue(d.allows(.normal))
    }

    func testHighCPUOnBatteryStopsIntensive() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.batteryMode = .alwaysOn
        let d = evaluate(PolicyInputs(source: .battery, batteryPercent: 90, highCPUStreak: 3), settings, memory: &memory)
        XCTAssertFalse(d.allows(.intensive))
        XCTAssertTrue(d.allows(.normal))
    }

    func testAlwaysOnOffStillStopsNonEssentialOnLowBattery() {
        var memory = PolicyMemory()
        var settings = PowerSettings()
        settings.alwaysOnEnabled = false
        settings.batteryThresholdPercent = 30
        let d = evaluate(PolicyInputs(source: .battery, batteryPercent: 10), settings, memory: &memory)
        XCTAssertEqual(d.mode, .off)
        XCTAssertEqual(d.allowedPriorities, [.essential])
    }

    func testUnknownBatteryPercentDoesNotTrip() {
        var memory = PolicyMemory()
        let d = evaluate(PolicyInputs(source: .battery, batteryPercent: nil), memory: &memory)
        XCTAssertEqual(d.mode, .fullBattery)
        XCTAssertTrue(d.reasons.contains { $0.contains("unavailable") })
    }
}
