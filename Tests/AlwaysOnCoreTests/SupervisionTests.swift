import XCTest
@testable import AlwaysOnCore

final class BackoffTests: XCTestCase {
    func testExponentialGrowthAndCap() {
        let delays = (1...8).map { Backoff.delay(attempt: $0, base: 2, max: 60, multiplier: 2) }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 60, 60, 60])
    }

    func testJitterStaysInBounds() {
        for r in [0.0, 0.25, 0.5, 0.75, 0.999] {
            let d = Backoff.delay(attempt: 3, base: 2, max: 60, multiplier: 2, jitterFraction: 0.2, random: { r })
            XCTAssertGreaterThanOrEqual(d, 8 * 0.8 - 0.0001)
            XCTAssertLessThanOrEqual(d, 8 * 1.2 + 0.0001)
        }
    }

    func testHugeAttemptDoesNotOverflow() {
        XCTAssertEqual(Backoff.delay(attempt: 10_000, base: 1, max: 300), 300)
    }

    func testTrackerResets() {
        var tracker = BackoffTracker(base: 5, max: 300)
        let first = tracker.recordFailure()
        _ = tracker.recordFailure()
        tracker.reset()
        XCTAssertEqual(tracker.failures, 0)
        XCTAssertLessThanOrEqual(first, 5.5)
    }
}

final class ServiceRuntimeTests: XCTestCase {
    private func spec(_ policy: RestartPolicy = .onCrash, max: Int = 3) -> ServiceSpec {
        var backoff = BackoffSettings()
        backoff.baseSeconds = 1
        backoff.maxSeconds = 8
        backoff.jitterFraction = 0
        backoff.maxRestartsInWindow = max
        backoff.windowSeconds = 100
        backoff.stableAfterSeconds = 30
        return ServiceSpec(id: "s", name: "S", kind: .command, path: "/bin/true", restartPolicy: policy, backoff: backoff)
    }

    func testCrashSchedulesBackoffRestarts() {
        var r = ServiceRuntime(spec: spec())
        let t0 = Date(timeIntervalSince1970: 1000)
        r.markLaunching(now: t0)
        r.markRunning(pid: 42)
        let crash = ExitInfo(reason: .signaled, code: 11, requested: false)
        XCTAssertEqual(r.handleExit(crash, now: t0.addingTimeInterval(1)), .restart(after: 1))
        XCTAssertEqual(r.state, .restarting)
        XCTAssertNotNil(r.lastCrashAt)
        r.markLaunching(now: t0.addingTimeInterval(2))
        XCTAssertEqual(r.handleExit(crash, now: t0.addingTimeInterval(3)), .restart(after: 2))
        r.markLaunching(now: t0.addingTimeInterval(5))
        XCTAssertEqual(r.handleExit(crash, now: t0.addingTimeInterval(6)), .restart(after: 4))
        r.markLaunching(now: t0.addingTimeInterval(10))
        XCTAssertEqual(r.handleExit(crash, now: t0.addingTimeInterval(11)), .giveUp)
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(r.restartCount, 3)
        XCTAssertTrue(r.lastExitDescription?.contains("SIGSEGV") ?? false)
    }

    func testStableRunResetsBackoff() {
        var r = ServiceRuntime(spec: spec(max: 100))
        let t0 = Date(timeIntervalSince1970: 1000)
        let crash = ExitInfo(reason: .exited, code: 1, requested: false)
        r.markLaunching(now: t0)
        _ = r.handleExit(crash, now: t0.addingTimeInterval(1))
        r.markLaunching(now: t0.addingTimeInterval(2))
        XCTAssertEqual(r.handleExit(crash, now: t0.addingTimeInterval(3)), .restart(after: 2))
        r.markLaunching(now: t0.addingTimeInterval(10))
        // Ran for 60 s (> stableAfter 30 s): backoff starts over.
        XCTAssertEqual(r.handleExit(crash, now: t0.addingTimeInterval(70)), .restart(after: 1))
    }

    func testCleanExitNotRestartedUnderOnCrash() {
        var r = ServiceRuntime(spec: spec(.onCrash))
        r.markLaunching(now: Date())
        XCTAssertEqual(r.handleExit(ExitInfo(reason: .exited, code: 0, requested: false), now: Date()), .none)
        XCTAssertEqual(r.state, .stopped)
    }

    func testAlwaysPolicyRestartsCleanExit() {
        var r = ServiceRuntime(spec: spec(.always))
        r.markLaunching(now: Date())
        if case .restart = r.handleExit(ExitInfo(reason: .exited, code: 0, requested: false), now: Date()) {} else {
            XCTFail("expected restart")
        }
    }

    func testNeverPolicyLeavesCrashed() {
        var r = ServiceRuntime(spec: spec(.never))
        r.markLaunching(now: Date())
        XCTAssertEqual(r.handleExit(ExitInfo(reason: .exited, code: 3, requested: false), now: Date()), .none)
        XCTAssertEqual(r.state, .crashed)
    }

    func testRequestedStopIsNotACrash() {
        var r = ServiceRuntime(spec: spec())
        r.markLaunching(now: Date())
        r.markRunning(pid: 1)
        r.markManualStop()
        XCTAssertEqual(r.handleExit(ExitInfo(reason: .signaled, code: 15, requested: true), now: Date()), .none)
        XCTAssertEqual(r.state, .stopped)
        XCTAssertNil(r.lastCrashAt)
    }

    func testSuspendedStaysSuspendedAfterRequestedExit() {
        var r = ServiceRuntime(spec: spec())
        r.markLaunching(now: Date())
        r.markRunning(pid: 1)
        r.markSuspended(reason: "battery")
        _ = r.handleExit(ExitInfo(reason: .signaled, code: 15, requested: true), now: Date())
        XCTAssertEqual(r.state, .suspended)
    }

    func testManualStartClearsFailure() {
        var r = ServiceRuntime(spec: spec(max: 1))
        r.markLaunching(now: Date())
        _ = r.handleExit(ExitInfo(reason: .exited, code: 1, requested: false), now: Date())
        r.markLaunching(now: Date())
        XCTAssertEqual(r.handleExit(ExitInfo(reason: .exited, code: 1, requested: false), now: Date()), .giveUp)
        r.markManualStart()
        XCTAssertEqual(r.state, .stopped)
        XCTAssertEqual(r.consecutiveFailures, 0)
    }
}

/// End-to-end tests of the supervisor with real child processes (/bin/sh).
final class ServiceSupervisorTests: XCTestCase {
    private var tempHome: URL!
    private var logger: EventLogger!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("aoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        logger = EventLogger(fileURL: nil)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    private func makeSupervisor() -> ServiceSupervisor {
        let paths = UserPaths(home: tempHome)
        return ServiceSupervisor(launchers: [CommandLauncher(paths: paths)], inspector: nil, logger: logger,
                                 registryURL: paths.pidRegistry, stopGrace: 2, random: { 0.5 })
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    private func shellSpec(_ script: String, id: String = "svc", priority: ServicePriority = .normal,
                           policy: RestartPolicy = .onCrash, maxRestarts: Int = 10) -> ServiceSpec {
        var backoff = BackoffSettings()
        backoff.baseSeconds = 0.5
        backoff.maxSeconds = 1
        backoff.jitterFraction = 0
        backoff.maxRestartsInWindow = maxRestarts
        return ServiceSpec(id: id, name: id, kind: .command, path: "/bin/sh", arguments: ["-c", script],
                           restartPolicy: policy, priority: priority, backoff: backoff)
    }

    func testLaunchesAndReportsRunning() {
        let sup = makeSupervisor()
        sup.apply(specs: [shellSpec("sleep 30")])
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .running })
        XCTAssertNotNil(sup.statuses().first?.pid)
        sup.stopAll(kinds: [.command])
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .stopped })
    }

    func testCrashIsRestartedThenGivesUp() {
        let sup = makeSupervisor()
        sup.apply(specs: [shellSpec("exit 3", maxRestarts: 2)])
        XCTAssertTrue(waitUntil(15) { sup.statuses().first?.state == .failed })
        let status = sup.statuses().first
        XCTAssertEqual(status?.restartCount, 2)
        XCTAssertEqual(status?.lastExitDescription, "exited with status 3")
        XCTAssertNotNil(status?.lastCrashAt)
    }

    func testPolicySuspendsAndResumes() {
        let sup = makeSupervisor()
        sup.apply(specs: [shellSpec("sleep 30", priority: .normal)])
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .running })
        sup.setAllowedPriorities([.essential], reason: "battery low")
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .suspended && sup.statuses().first?.pid == nil })
        sup.setAllowedPriorities(ServicePriority.allCases, reason: "ac")
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .running })
        sup.stopAll(kinds: [.command])
    }

    func testManualStopPreventsRestart() {
        let sup = makeSupervisor()
        sup.apply(specs: [shellSpec("sleep 30")])
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .running })
        XCTAssertNil(sup.stop(id: "svc"))
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .stopped })
        usleep(1_500_000)
        XCTAssertEqual(sup.statuses().first?.state, .stopped)
        XCTAssertNil(sup.start(id: "svc"))
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .running })
        sup.stopAll(kinds: [.command])
    }

    func testRestartRelaunchesWithNewPID() {
        let sup = makeSupervisor()
        sup.apply(specs: [shellSpec("sleep 30")])
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .running })
        let firstPID = sup.statuses().first?.pid
        XCTAssertNil(sup.restart(id: "svc"))
        XCTAssertTrue(waitUntil { let s = sup.statuses().first; return s?.state == .running && s?.pid != firstPID })
        sup.stopAll(kinds: [.command])
    }

    func testNetworkGate() {
        let sup = makeSupervisor()
        var spec = shellSpec("sleep 30")
        spec.requiresNetwork = true
        sup.setNetworkAvailable(false)
        sup.apply(specs: [spec])
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .waitingForNetwork })
        sup.setNetworkAvailable(true)
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .running })
        sup.stopAll(kinds: [.command])
    }

    func testInvalidPathIsReportedNotCrashingSupervisor() {
        let sup = makeSupervisor()
        let spec = ServiceSpec(id: "bad", name: "bad", kind: .command, path: "/nonexistent/binary",
                               backoff: { var b = BackoffSettings(); b.maxRestartsInWindow = 1; b.baseSeconds = 0.5; b.jitterFraction = 0; return b }())
        sup.apply(specs: [spec])
        XCTAssertTrue(waitUntil(10) { sup.statuses().first?.state == .failed })
        XCTAssertTrue(sup.statuses().first?.lastExitDescription?.contains("not found") ?? false)
    }

    func testOutputGoesToServiceLog() throws {
        let sup = makeSupervisor()
        let spec = shellSpec("echo hello-from-service; sleep 30", id: "logger")
        sup.apply(specs: [spec])
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .running })
        let logURL = UserPaths(home: tempHome).serviceLog(for: spec)
        XCTAssertTrue(waitUntil { ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").contains("hello-from-service") })
        sup.stopAll(kinds: [.command])
    }

    func testRemovingServiceStopsIt() {
        let sup = makeSupervisor()
        sup.apply(specs: [shellSpec("sleep 30")])
        XCTAssertTrue(waitUntil { sup.statuses().first?.state == .running })
        sup.apply(specs: [])
        XCTAssertTrue(waitUntil { sup.statuses().isEmpty })
    }
}
