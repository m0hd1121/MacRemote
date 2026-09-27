import XCTest
@testable import AlwaysOnCore

/// Exercises the root helper logic against a simulated pmset / pfctl.
final class HelperEngineTests: XCTestCase {
    final class FakeSystem: CommandRunning, @unchecked Sendable {
        var sleepDisabled = false
        var pfMainHasAppleAnchor = true
        var anchorRules = ""
        var pfEnableCount = 0
        var commands: [String] = []
        var failPMSet = false
        let lock = NSLock()

        func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) throws -> CommandResult {
            lock.lock(); defer { lock.unlock() }
            commands.append(([executable] + arguments).joined(separator: " "))
            func ok(_ out: String = "", _ err: String = "") -> CommandResult { CommandResult(status: 0, stdout: out, stderr: err, timedOut: false) }
            switch (executable, arguments) {
            case (SystemPaths.pmset, ["-g"]):
                return ok(sleepDisabled ? "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n" : "Currently in use:\n sleep 1\n")
            case (SystemPaths.pmset, let args) where args.starts(with: ["-a", "disablesleep"]):
                if failPMSet { return CommandResult(status: 1, stdout: "", stderr: "denied", timedOut: false) }
                sleepDisabled = args[2] == "1"
                return ok()
            case (SystemPaths.pfctl, ["-s", "rules"]):
                return ok(pfMainHasAppleAnchor ? "anchor \"com.apple/*\" all\n" : "")
            case (SystemPaths.pfctl, ["-f", "/etc/pf.conf"]):
                pfMainHasAppleAnchor = true
                return ok()
            case (SystemPaths.pfctl, ["-a", PFRules.anchorName, "-f", "-"]):
                anchorRules = String(decoding: stdin ?? Data(), as: UTF8.self)
                return ok()
            case (SystemPaths.pfctl, ["-E"]):
                pfEnableCount += 1
                return ok("", "pf enabled\nToken : 424242\n")
            case (SystemPaths.pfctl, ["-a", PFRules.anchorName, "-s", "rules"]):
                return ok(anchorRules)
            case (SystemPaths.pfctl, ["-a", PFRules.anchorName, "-F", "all"]):
                anchorRules = ""
                return ok()
            case (SystemPaths.pfctl, ["-X", "424242"]):
                return ok()
            default:
                return CommandResult(status: 127, stdout: "", stderr: "unexpected", timedOut: false)
            }
        }
    }

    private var facts = HelperPowerFacts(onBattery: false, batteryPercent: 100, thermal: .nominal)
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    func makeEngine(_ system: FakeSystem, stateURL: URL? = nil) -> HelperEngine {
        HelperEngine(stateURL: stateURL, runner: system, logger: EventLogger(fileURL: nil),
                     powerFacts: { [unowned self] in self.facts }, now: { [unowned self] in self.clock })
    }

    func lidRequest(enabled: Bool = true, battery: Bool = false, floor: Int = 25, lease: Double = 600) -> HelperRequest {
        HelperRequest(command: .setLidClosedOperation,
                      lidClosed: LidClosedRequest(enabled: enabled, allowOnBattery: battery, batteryFloorPercent: floor, leaseSeconds: lease))
    }

    func testApplyAndRevertLidOverride() {
        let system = FakeSystem()
        let engine = makeEngine(system)
        let response = engine.handle(lidRequest())
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertTrue(system.sleepDisabled)
        XCTAssertEqual(response.state?.lidOverrideApplied, true)
        XCTAssertEqual(response.state?.systemSleepDisabled, true)

        let off = engine.handle(lidRequest(enabled: false))
        XCTAssertTrue(off.ok)
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertEqual(off.state?.lastRevertReason, "disabled by agent")
    }

    func testLeaseExpiryReverts() {
        let system = FakeSystem()
        let engine = makeEngine(system)
        _ = engine.handle(lidRequest(lease: 120))
        clock = clock.addingTimeInterval(60)
        engine.safetyCheck()
        XCTAssertTrue(system.sleepDisabled, "lease still valid")
        clock = clock.addingTimeInterval(61)
        engine.safetyCheck()
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertTrue(engine.currentState.lastRevertReason?.contains("lease expired") ?? false)
    }

    func testRenewalExtendsLease() {
        let system = FakeSystem()
        let engine = makeEngine(system)
        _ = engine.handle(lidRequest(lease: 120))
        clock = clock.addingTimeInterval(100)
        _ = engine.handle(lidRequest(lease: 120))
        clock = clock.addingTimeInterval(100)
        engine.safetyCheck()
        XCTAssertTrue(system.sleepDisabled)
        XCTAssertEqual(system.commands.filter { $0.contains("disablesleep 1") }.count, 1, "renewal must not re-run pmset")
    }

    func testBatteryFloorEnforcedByHelper() {
        let system = FakeSystem()
        let engine = makeEngine(system)
        facts = HelperPowerFacts(onBattery: true, batteryPercent: 80, thermal: .nominal)
        XCTAssertFalse(engine.handle(lidRequest(battery: false)).ok, "battery not allowed")
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertTrue(engine.handle(lidRequest(battery: true, floor: 30)).ok)
        XCTAssertTrue(system.sleepDisabled)
        facts.batteryPercent = 30
        engine.safetyCheck()
        XCTAssertFalse(system.sleepDisabled)
    }

    func testDoesNotRevertAdministratorSetting() {
        let system = FakeSystem()
        system.sleepDisabled = true
        let engine = makeEngine(system)
        facts = HelperPowerFacts(onBattery: true, batteryPercent: 5, thermal: .critical)
        engine.safetyCheck()
        XCTAssertTrue(system.sleepDisabled, "helper must only revert what it applied")
    }

    func testPMSetFailureIsReported() {
        let system = FakeSystem()
        system.failPMSet = true
        let engine = makeEngine(system)
        let response = engine.handle(lidRequest())
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.state?.lidOverrideApplied, false)
    }

    func testInvalidRequestRejected() {
        let engine = makeEngine(FakeSystem())
        XCTAssertFalse(engine.handle(lidRequest(floor: 99)).ok)
        XCTAssertFalse(engine.handle(HelperRequest(command: .setFirewall)).ok)
    }

    func testFirewallLifecycle() {
        let system = FakeSystem()
        system.pfMainHasAppleAnchor = false
        let engine = makeEngine(system)
        let on = engine.handle(HelperRequest(command: .setFirewall, firewall: FirewallRequest(enabled: true, tcpPorts: [22, 5900], udpPorts: [])))
        XCTAssertTrue(on.ok, on.error ?? "")
        XCTAssertEqual(on.state?.firewallActive, true)
        XCTAssertEqual(on.state?.pfToken, "424242")
        XCTAssertTrue(system.commands.contains("\(SystemPaths.pfctl) -f /etc/pf.conf"))
        XCTAssertTrue(system.anchorRules.contains("from 100.64.0.0/10 to any port { 22 5900 }"))

        // Same ports again: no reload, no second enable reference.
        _ = engine.handle(HelperRequest(command: .setFirewall, firewall: FirewallRequest(enabled: true, tcpPorts: [5900, 22], udpPorts: [])))
        XCTAssertEqual(system.pfEnableCount, 1)

        let off = engine.handle(HelperRequest(command: .setFirewall, firewall: FirewallRequest(enabled: false, tcpPorts: [], udpPorts: [])))
        XCTAssertTrue(off.ok)
        XCTAssertEqual(off.state?.firewallActive, false)
        XCTAssertNil(off.state?.pfToken)
        XCTAssertTrue(system.commands.contains("\(SystemPaths.pfctl) -X 424242"))
        XCTAssertEqual(system.anchorRules, "")
    }

    func testStartupRecoveryRestoresFirewallAndExpiresLease() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateURL = dir.appendingPathComponent("state.json")
        let system = FakeSystem()
        let engine = makeEngine(system, stateURL: stateURL)
        _ = engine.handle(lidRequest(lease: 300))
        _ = engine.handle(HelperRequest(command: .setFirewall, firewall: FirewallRequest(enabled: true, tcpPorts: [22], udpPorts: [])))

        // Simulate reboot: pf anchor gone, time passed beyond the lease.
        system.anchorRules = ""
        clock = clock.addingTimeInterval(3600)
        let rebooted = makeEngine(system, stateURL: stateURL)
        rebooted.startupRecovery()
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertTrue(rebooted.currentState.firewallActive)
        XCTAssertTrue(system.anchorRules.contains("port { 22 }"))
    }

    func testRevertAll() {
        let system = FakeSystem()
        let engine = makeEngine(system)
        _ = engine.handle(lidRequest())
        _ = engine.handle(HelperRequest(command: .setFirewall, firewall: FirewallRequest(enabled: true, tcpPorts: [22], udpPorts: [])))
        engine.revertAll()
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertEqual(system.anchorRules, "")
        XCTAssertFalse(engine.currentState.firewallEnabled)
    }

    func testAuthorizedUIDParsing() {
        XCTAssertEqual(AuthorizedUIDs.parse("# comment\n501\n\n 502 \nabc\n"), [501, 502])
    }

    func testStatusPageEscapesContent() {
        var s = StatusSnapshot(generatedAt: Date(), refreshIntervalSeconds: 15, agent: AgentInfo(version: "1", pid: 1, startedAt: Date()))
        s.services = [ServiceStatus(id: "x", name: "<script>alert(1)</script>", kind: .command, priority: .normal, state: .running)]
        let html = StatusPage.render(s, viewer: "a&b@example.com")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("a&amp;b@example.com"))
    }
}

extension HelperEngineTests {
    func testReleaseOnHelperStop() {
        let system = FakeSystem()
        let engine = makeEngine(system)
        _ = engine.handle(lidRequest())
        engine.releaseLidOverride(reason: "helper stopped")
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertEqual(engine.currentState.lastRevertReason, "helper stopped")
    }
}
