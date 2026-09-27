import XCTest
@testable import AlwaysOnCore

final class HelperTests: XCTestCase {
    func testValidation() {
        XCTAssertNoThrow(try HelperValidation.validate(LidClosedRequest(enabled: true, allowOnBattery: false, batteryFloorPercent: 25)))
        XCTAssertThrowsError(try HelperValidation.validate(LidClosedRequest(enabled: true, allowOnBattery: false, batteryFloorPercent: 5)))
        XCTAssertThrowsError(try HelperValidation.validate(LidClosedRequest(enabled: true, allowOnBattery: false, batteryFloorPercent: 25, leaseSeconds: 10)))
        XCTAssertThrowsError(try HelperValidation.validate(LidClosedRequest(enabled: true, allowOnBattery: false, batteryFloorPercent: 25, leaseSeconds: .infinity)))
        XCTAssertNoThrow(try HelperValidation.validate(FirewallRequest(enabled: true, tcpPorts: [22, 5900], udpPorts: [])))
        XCTAssertThrowsError(try HelperValidation.validate(FirewallRequest(enabled: true, tcpPorts: [0], udpPorts: [])))
        XCTAssertThrowsError(try HelperValidation.validate(FirewallRequest(enabled: true, tcpPorts: Array(1...17), udpPorts: [])))
    }

    func testSafetyRevertsOnLeaseExpiry() {
        var state = HelperState()
        state.lidOverrideRequested = true
        state.lidOverrideApplied = true
        state.leaseExpiresAt = Date(timeIntervalSince1970: 100)
        let ac = HelperPowerFacts(onBattery: false, batteryPercent: 100, thermal: .nominal)
        XCTAssertNil(HelperSafety.revertReason(state: state, facts: ac, now: Date(timeIntervalSince1970: 50)))
        XCTAssertNotNil(HelperSafety.revertReason(state: state, facts: ac, now: Date(timeIntervalSince1970: 100)))
    }

    func testSafetyOnBattery() {
        var state = HelperState()
        state.lidOverrideRequested = true
        state.lidOverrideApplied = true
        state.leaseExpiresAt = Date.distantFuture
        state.batteryFloorPercent = 30
        let battery = HelperPowerFacts(onBattery: true, batteryPercent: 80, thermal: .nominal)
        XCTAssertNotNil(HelperSafety.revertReason(state: state, facts: battery, now: Date()), "battery not allowed")
        state.allowOnBattery = true
        XCTAssertNil(HelperSafety.revertReason(state: state, facts: battery, now: Date()))
        XCTAssertNotNil(HelperSafety.revertReason(state: state, facts: HelperPowerFacts(onBattery: true, batteryPercent: 30, thermal: .nominal), now: Date()))
        XCTAssertNotNil(HelperSafety.revertReason(state: state, facts: HelperPowerFacts(onBattery: true, batteryPercent: nil, thermal: .nominal), now: Date()))
        XCTAssertNotNil(HelperSafety.revertReason(state: state, facts: HelperPowerFacts(onBattery: true, batteryPercent: 80, thermal: .serious), now: Date()))
        XCTAssertNotNil(HelperSafety.revertReason(state: state, facts: HelperPowerFacts(onBattery: false, batteryPercent: 80, thermal: .critical), now: Date()))
    }

    func testSafetyIgnoresOverridesItDidNotApply() {
        var state = HelperState()
        state.lidOverrideApplied = false
        XCTAssertNil(HelperSafety.revertReason(state: state, facts: HelperPowerFacts(onBattery: true, batteryPercent: 1, thermal: .critical), now: Date()))
    }

    func testMayApply() {
        let request = LidClosedRequest(enabled: true, allowOnBattery: false, batteryFloorPercent: 20)
        XCTAssertNil(HelperSafety.mayApply(request: request, facts: HelperPowerFacts(onBattery: false, batteryPercent: nil, thermal: .fair)))
        XCTAssertNotNil(HelperSafety.mayApply(request: request, facts: HelperPowerFacts(onBattery: true, batteryPercent: 90, thermal: .nominal)))
    }

    func testPFRules() {
        let rules = PFRules.render(tcpPorts: [5900, 22, 22], udpPorts: [])
        XCTAssertTrue(rules.contains("pass in quick inet proto tcp from 100.64.0.0/10 to any port { 22 5900 }"))
        XCTAssertTrue(rules.contains("pass in quick inet6 proto tcp from fd7a:115c:a1e0::/48 to any port { 22 5900 }"))
        XCTAssertTrue(rules.contains("block drop in quick proto tcp from any to any port { 22 5900 }"))
        XCTAssertFalse(rules.contains("udp"))
        // pass rules must precede the block rule (pf evaluates quick rules in order)
        let passIndex = rules.range(of: "pass in quick inet proto tcp")!.lowerBound
        let blockIndex = rules.range(of: "block drop")!.lowerBound
        XCTAssertLessThan(passIndex, blockIndex)
        XCTAssertFalse(PFRules.render(tcpPorts: [], udpPorts: []).contains("block"))
    }
}

final class DiagnosticsTests: XCTestCase {
    private func snapshot() -> StatusSnapshot {
        var s = StatusSnapshot(generatedAt: Date(), refreshIntervalSeconds: 15,
                               agent: AgentInfo(version: "1", pid: 1, startedAt: Date()))
        s.network.pathSatisfied = true
        s.network.dnsWorking = true
        s.network.internetReachable = true
        s.tailscale.installed = true
        s.tailscale.connected = true
        s.tailscale.ipv4 = "100.64.1.2"
        s.tailscale.dnsName = "mac.tail.ts.net"
        s.power.source = .ac
        s.power.lid = .open
        s.power.clamshellCausesSleep = true
        var memory = PolicyMemory()
        s.power.policy = PowerPolicy.evaluate(PolicyInputs(source: .ac, batteryPercent: nil), settings: PowerSettings(), memory: &memory)
        s.power.assertions.idleSleepPrevented = true
        s.power.assertions.systemSleepPrevented = true
        return s
    }

    func testHealthySnapshot() {
        let s = snapshot()
        XCTAssertEqual(HealthSummarizer.summarize(s).level, .healthy)
        let report = DiagnosticsEngine.evaluate(s, context: DiagnosticsContext())
        XCTAssertEqual(report.checks.first { $0.id == "tailscale.connected" }?.outcome, .pass)
        XCTAssertEqual(report.checks.first { $0.id == "power.assertions" }?.outcome, .pass)
    }

    func testLidWarningExplainsSleep() {
        let report = DiagnosticsEngine.evaluate(snapshot(), context: DiagnosticsContext())
        let lid = report.checks.first { $0.id == "power.lidCapable" }
        XCTAssertEqual(lid?.outcome, .warning)
        XCTAssertTrue(lid?.detail.contains("put the Mac to sleep") ?? false)
        XCTAssertNotNil(lid?.remedy)
    }

    func testLidPassWhenSleepDisabled() {
        var s = snapshot()
        s.power.systemSleepDisabled = true
        XCTAssertEqual(DiagnosticsEngine.evaluate(s, context: DiagnosticsContext()).checks.first { $0.id == "power.lidCapable" }?.outcome, .pass)
    }

    func testTailscaleDownExplainsRemoteAccess() {
        var s = snapshot()
        s.tailscale.connected = false
        s.tailscale.backendState = "NeedsLogin"
        s.tailscale.lastError = TailscaleStatusParser.explain(backendState: "NeedsLogin")
        let report = DiagnosticsEngine.evaluate(s, context: DiagnosticsContext())
        let ts = report.checks.first { $0.id == "tailscale.connected" }
        XCTAssertEqual(ts?.outcome, .fail)
        XCTAssertTrue(ts?.detail.hasPrefix("Remote access unavailable because Tailscale is not connected") ?? false)
        XCTAssertEqual(report.checks.first { $0.id == "remote.tailscale" }?.outcome, .fail)
        XCTAssertEqual(HealthSummarizer.summarize(s).level, .unhealthy)
    }

    func testSleepIntervalIsReported() {
        var s = snapshot()
        s.power.lastSleepAt = Date(timeIntervalSinceNow: -3600)
        s.power.lastWakeAt = Date(timeIntervalSinceNow: -600)
        let awake = DiagnosticsEngine.evaluate(s, context: DiagnosticsContext()).checks.first { $0.id == "power.awake" }
        XCTAssertTrue(awake?.detail.contains("because macOS had entered system sleep") ?? false)
    }

    func testExposedListenersWarnUnlessRestricted() {
        var s = snapshot()
        let listeners = [ListeningSocket(proto: "tcp4", address: "*", port: 22, exposure: .wildcard)]
        var context = DiagnosticsContext(listeners: listeners, restrictedTCPPorts: [22])
        XCTAssertEqual(DiagnosticsEngine.evaluate(s, context: context).checks.first { $0.id == "security.listeners" }?.outcome, .warning)
        s.remoteAccess.firewallRestricted = true
        XCTAssertEqual(DiagnosticsEngine.evaluate(s, context: context).checks.first { $0.id == "security.listeners" }?.outcome, .pass)
        context.restrictedTCPPorts = []
        XCTAssertEqual(DiagnosticsEngine.evaluate(s, context: context).checks.first { $0.id == "security.listeners" }?.outcome, .warning)
    }

    func testFailedServiceDegradesHealth() {
        var s = snapshot()
        s.services = [ServiceStatus(id: "a", name: "A", kind: .command, priority: .normal, state: .failed, note: "Gave up")]
        XCTAssertEqual(HealthSummarizer.summarize(s).level, .degraded)
        XCTAssertEqual(DiagnosticsEngine.evaluate(s, context: DiagnosticsContext()).checks.first { $0.id == "services.a" }?.outcome, .fail)
    }

    func testSnapshotStaleness() {
        let s = StatusSnapshot(generatedAt: Date(timeIntervalSinceNow: -100), refreshIntervalSeconds: 15,
                               agent: AgentInfo(version: "1", pid: 1, startedAt: Date()))
        XCTAssertTrue(s.isStale())
        XCTAssertEqual(DiagnosticsEngine.agentUnavailableCheck(lastSnapshot: s).outcome, .fail)
    }

    func testSnapshotCodableRoundTrip() throws {
        let s = snapshot()
        let data = try JSONCoding.encoder().encode(s)
        let back = try JSONCoding.decoder().decode(StatusSnapshot.self, from: data)
        XCTAssertEqual(back.tailscale, s.tailscale)
        XCTAssertEqual(back.power.policy, s.power.policy)
    }
}

/// TailscaleMonitor against a scripted CLI and a fake app environment.
final class TailscaleMonitorTests: XCTestCase {
    final class FakeRunner: CommandRunning, @unchecked Sendable {
        var statusOutputs: [CommandResult]
        var calls: [[String]] = []
        let lock = NSLock()

        init(_ outputs: [CommandResult]) { statusOutputs = outputs }

        func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) throws -> CommandResult {
            lock.lock(); defer { lock.unlock() }
            calls.append(arguments)
            if arguments.first == "up" { return CommandResult(status: 0, stdout: "", stderr: "", timedOut: false) }
            return statusOutputs.count > 1 ? statusOutputs.removeFirst() : statusOutputs[0]
        }
    }

    final class FakeEnvironment: TailscaleHostEnvironment {
        var running = false
        var launches = 0
        func isAppRunning(bundleID: String) -> Bool { running }
        func launchApp(bundleID: String) -> Bool { launches += 1; running = true; return true }
    }

    private let install = TailscaleInstallation(cliPath: "/fake/tailscale", variant: .standalone, appBundleID: TailscaleCLI.standaloneBundleID)

    func testConnectedStatus() {
        let runner = FakeRunner([CommandResult(status: 0, stdout: TailscaleParserTests.runningJSON, stderr: "", timedOut: false)])
        let monitor = TailscaleMonitor(settings: TailscaleSettings(), logger: EventLogger(fileURL: nil), runner: runner,
                                       environment: nil, locate: { [install] _ in install })
        let status = monitor.checkNow()
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.ipv4, "100.101.102.103")
        XCTAssertNotNil(status.lastConnectedAt)
        XCTAssertEqual(status.variant, .standalone)
    }

    func testStoppedTriggersUpOnlyWhenAutoReconnect() {
        let stopped = CommandResult(status: 1, stdout: #"{"BackendState":"Stopped"}"#, stderr: "", timedOut: false)
        var settings = TailscaleSettings()
        settings.autoReconnect = false
        let runner = FakeRunner([stopped])
        let monitor = TailscaleMonitor(settings: settings, logger: EventLogger(fileURL: nil), runner: runner,
                                       environment: nil, locate: { [install] _ in install })
        XCTAssertFalse(monitor.checkNow().connected)
        XCTAssertFalse(runner.calls.contains(["up"]))

        settings.autoReconnect = true
        let runner2 = FakeRunner([stopped])
        let monitor2 = TailscaleMonitor(settings: settings, logger: EventLogger(fileURL: nil), runner: runner2,
                                        environment: nil, locate: { [install] _ in install })
        let status = monitor2.checkNow()
        XCTAssertTrue(runner2.calls.contains(["up"]))
        XCTAssertTrue(status.lastRecoveryAction?.contains("tailscale up") ?? false)
    }

    func testUnresponsiveRelaunchesApp() {
        let dead = CommandResult(status: 1, stdout: "", stderr: "failed to connect to local Tailscale service", timedOut: false)
        let env = FakeEnvironment()
        let monitor = TailscaleMonitor(settings: TailscaleSettings(), logger: EventLogger(fileURL: nil), runner: FakeRunner([dead]),
                                       environment: env, locate: { [install] _ in install })
        let status = monitor.checkNow()
        XCTAssertFalse(status.connected)
        XCTAssertEqual(env.launches, 1)
        XCTAssertTrue(status.lastError?.contains("not responding") ?? false)
    }

    func testNeedsLoginNeverRunsUp() {
        let needsLogin = CommandResult(status: 0, stdout: #"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/abc"}"#, stderr: "", timedOut: false)
        let runner = FakeRunner([needsLogin])
        let monitor = TailscaleMonitor(settings: TailscaleSettings(), logger: EventLogger(fileURL: nil), runner: runner,
                                       environment: FakeEnvironment(), locate: { [install] _ in install })
        let status = monitor.checkNow()
        XCTAssertFalse(runner.calls.contains(["up"]))
        XCTAssertTrue(status.lastError?.contains("log in") ?? false)
    }

    func testNotInstalled() {
        let monitor = TailscaleMonitor(settings: TailscaleSettings(), logger: EventLogger(fileURL: nil), runner: FakeRunner([]),
                                       environment: nil, locate: { _ in nil })
        let status = monitor.checkNow()
        XCTAssertFalse(status.installed)
        XCTAssertTrue(status.lastError?.contains("tailscale.com/download") ?? false)
    }
}
