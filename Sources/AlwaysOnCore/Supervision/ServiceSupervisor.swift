import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Process start time (seconds since 1970) so a recycled PID is never mistaken for ours.
    public var startTime: Double?
}

public struct ProcessSample: Equatable, Sendable {
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?

    public init(cpuPercent: Double?, memoryBytes: UInt64?) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// Platform hooks for inspecting processes (libproc on macOS).
public protocol ProcessInspector: AnyObject {
    func startTime(pid: Int32) -> Double?
    func sample(pid: Int32) -> ProcessSample?
}

/// Supervises configured services: launch, crash detection, backoff restarts, policy-driven
/// suspension, orphan cleanup and metrics. All state lives on one serial queue.
public final class ServiceSupervisor {
    public var onChange: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.macalwayson.supervisor")
    private let launchers: [ServiceLauncher]
    private let inspector: ProcessInspector?
    private let logger: EventLogger
    private let registryURL: URL?
    private let random: () -> Double
    private let stopGrace: TimeInterval

    private var order: [String] = []
    private var runtimes: [String: ServiceRuntime] = [:]
    private var userStarted: Set<String> = []
    private var stopRequested: Set<String> = []
    private var instance: [String: Int] = [:]
    private var restartToken: [String: Int] = [:]
    private var samples: [String: ProcessSample] = [:]
    private var health: [String: Bool] = [:]
    private var allowed: Set<ServicePriority> = Set(ServicePriority.allCases)
    private var suspendReason = ""
    private var networkUp = true
    /// Kinds being shut down by `stopAll`; never relaunched afterwards.
    private var shutdownKinds: Set<ServiceKind> = []

    public init(launchers: [ServiceLauncher], inspector: ProcessInspector?, logger: EventLogger,
                registryURL: URL?, stopGrace: TimeInterval = 10,
                random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.launchers = launchers
        self.inspector = inspector
        self.logger = logger
        self.registryURL = registryURL
        self.stopGrace = stopGrace
        self.random = random
    }

    // MARK: Public API

    /// Replace the service list. New services are added, removed ones stopped, and running
    /// services whose launch parameters changed are restarted.
    public func apply(specs: [ServiceSpec]) {
        queue.async { [self] in
            let newIDs = specs.map(\.id)
            for id in order where !newIDs.contains(id) {
                if let runtime = runtimes[id], runtime.isActive, let pid = runtime.pid {
                    stopRequested.insert(id)
                    launcher(for: runtime.spec)?.stop(pid: pid, spec: runtime.spec, grace: stopGrace)
                }
                restartToken[id, default: 0] += 1
                runtimes[id] = nil
                userStarted.remove(id)
                logger.info("supervisor", "Removed service \(id)")
            }
            for spec in specs {
                if var runtime = runtimes[spec.id] {
                    let old = runtime.spec
                    runtime.spec = spec
                    runtimes[spec.id] = runtime
                    if Self.launchParametersChanged(old, spec), runtime.isActive, let pid = runtime.pid {
                        logger.info("supervisor", "\(spec.name): configuration changed; restarting")
                        stopRequested.insert(spec.id)
                        launcher(for: old)?.stop(pid: pid, spec: old, grace: stopGrace)
                        userStarted.insert(spec.id)
                    }
                } else {
                    runtimes[spec.id] = ServiceRuntime(spec: spec)
                }
            }
            order = newIDs
            reconcile()
        }
    }

    public func setAllowedPriorities(_ priorities: [ServicePriority], reason: String) {
        queue.async { [self] in
            let newSet = Set(priorities)
            guard newSet != allowed || reason != suspendReason else { return }
            allowed = newSet
            suspendReason = reason
            reconcile()
        }
    }

    public func setNetworkAvailable(_ up: Bool) {
        queue.async { [self] in
            guard up != networkUp else { return }
            networkUp = up
            reconcile()
        }
    }

    public func start(id: String) -> String? {
        queue.sync {
            guard var runtime = runtimes[id] else { return "Unknown service \(id)" }
            let errors = runtime.spec.validationErrors()
            guard errors.isEmpty else { return errors.joined(separator: " ") }
            runtime.markManualStart()
            runtimes[id] = runtime
            userStarted.insert(id)
            logger.info("supervisor", "\(runtime.spec.name): manual start")
            reconcile()
            return nil
        }
    }

    public func stop(id: String) -> String? {
        queue.sync {
            guard var runtime = runtimes[id] else { return "Unknown service \(id)" }
            restartToken[id, default: 0] += 1
            userStarted.remove(id)
            if runtime.isActive, let pid = runtime.pid {
                stopRequested.insert(id)
                launcher(for: runtime.spec)?.stop(pid: pid, spec: runtime.spec, grace: stopGrace)
            }
            runtime.markManualStop()
            runtimes[id] = runtime
            logger.info("supervisor", "\(runtime.spec.name): manual stop")
            notify()
            return nil
        }
    }

    public func restart(id: String) -> String? {
        queue.sync {
            guard var runtime = runtimes[id] else { return "Unknown service \(id)" }
            runtime.markManualStart()
            runtimes[id] = runtime
            userStarted.insert(id)
            if runtime.isActive, let pid = runtime.pid {
                stopRequested.insert(id)
                launcher(for: runtime.spec)?.stop(pid: pid, spec: runtime.spec, grace: stopGrace)
                // The exit handler relaunches because the service is still wanted.
            } else {
                reconcile()
            }
            logger.info("supervisor", "\(runtime.spec.name): manual restart")
            return nil
        }
    }

    public func statuses() -> [ServiceStatus] {
        queue.sync {
            order.compactMap { id in
                guard let r = runtimes[id] else { return nil }
                let sample = r.isActive ? samples[id] : nil
                return ServiceStatus(
                    id: id, name: r.spec.name, kind: r.spec.kind, priority: r.spec.priority, state: r.state,
                    pid: r.pid, cpuPercent: sample?.cpuPercent, memoryBytes: sample?.memoryBytes,
                    lastLaunchAt: r.lastLaunchAt, lastExitAt: r.lastExitAt, lastCrashAt: r.lastCrashAt,
                    lastExitDescription: r.lastExitDescription, restartCount: r.restartCount,
                    nextRestartAt: r.nextRestartAt, healthy: r.state == .running ? health[id] : nil, note: r.note
                )
            }
        }
    }

    /// Samples CPU/memory of supervised PIDs and runs TCP health checks.
    public func refreshMetrics(healthProbe: (Int) -> Bool = { TCPProbe.connect(host: "127.0.0.1", port: $0, timeout: 2).succeeded }) {
        let targets: [(String, Int32?, Int?)] = queue.sync {
            order.compactMap { id in
                guard let r = runtimes[id], r.state == .running else { return nil }
                return (id, r.pid, r.spec.healthCheckPort)
            }
        }
        var newSamples: [String: ProcessSample] = [:]
        var newHealth: [String: Bool] = [:]
        for (id, pid, port) in targets {
            if let pid, let sample = inspector?.sample(pid: pid) { newSamples[id] = sample }
            if let port { newHealth[id] = healthProbe(port) }
        }
        let sampled = newSamples
        let checked = newHealth
        queue.async { [self] in
            for (id, ok) in checked where health[id] != ok {
                if let name = runtimes[id]?.spec.name {
                    if ok { logger.info("supervisor", "\(name): health check passing") }
                    else { logger.warning("supervisor", "\(name): health check failing (port not accepting connections)") }
                }
            }
            samples = sampled
            health = checked
        }
    }

    /// Terminates services of the given kinds and waits up to the grace period.
    public func stopAll(kinds: Set<ServiceKind>) {
        queue.sync {
            shutdownKinds.formUnion(kinds)
            for id in order {
                guard let runtime = runtimes[id], kinds.contains(runtime.spec.kind) else { continue }
                restartToken[id, default: 0] += 1
                if runtime.isActive, let pid = runtime.pid {
                    stopRequested.insert(id)
                    launcher(for: runtime.spec)?.stop(pid: pid, spec: runtime.spec, grace: stopGrace)
                }
            }
        }
        let deadline = Date().addingTimeInterval(stopGrace + 1)
        while Date() < deadline {
            let active = queue.sync { runtimes.values.contains { kinds.contains($0.spec.kind) && $0.isActive } }
            if !active { break }
            usleep(100_000)
        }
    }

    /// Terminates command services left over by a previous agent instance (e.g. after an
    /// agent crash). PIDs are only signalled if their start time matches the record.
    public func cleanupOrphans() {
        guard let registryURL, let data = try? Data(contentsOf: registryURL),
              let records = try? JSONDecoder().decode([String: ProcessIdentity].self, from: data) else { return }
        for (id, record) in records {
            guard let recorded = record.startTime, let actual = inspector?.startTime(pid: record.pid),
                  abs(recorded - actual) < 2 else { continue }
            logger.warning("supervisor", "Terminating orphaned process \(record.pid) of service \(id) from a previous agent run")
            kill(record.pid, SIGTERM)
            let pid = record.pid
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + stopGrace) { [inspector] in
                if let now = inspector?.startTime(pid: pid), abs(now - recorded) < 2 { kill(pid, SIGKILL) }
            }
        }
        try? FileManager.default.removeItem(at: registryURL)
    }

    // MARK: Internals (queue only)

    private func launcher(for spec: ServiceSpec) -> ServiceLauncher? {
        launchers.first { $0.canLaunch(spec) }
    }

    private func wantsToRun(_ runtime: ServiceRuntime) -> Bool {
        guard !runtime.manuallyStopped, runtime.state != .failed, !shutdownKinds.contains(runtime.spec.kind) else { return false }
        return runtime.spec.launchAtStart || userStarted.contains(runtime.spec.id)
    }

    private func reconcile() {
        for id in order {
            guard var runtime = runtimes[id] else { continue }
            let permitted = allowed.contains(runtime.spec.priority)
            switch runtime.state {
            case .starting, .running:
                if !permitted, let pid = runtime.pid {
                    runtime.markSuspended(reason: suspendReason)
                    runtimes[id] = runtime
                    stopRequested.insert(id)
                    launcher(for: runtime.spec)?.stop(pid: pid, spec: runtime.spec, grace: stopGrace)
                    logger.info("supervisor", "\(runtime.spec.name): suspended by power policy (\(suspendReason))")
                }
            case .restarting:
                if !permitted {
                    restartToken[id, default: 0] += 1
                    runtime.markSuspended(reason: suspendReason)
                    runtimes[id] = runtime
                }
            case .stopped, .suspended, .waitingForNetwork:
                // A suspended instance may still be shutting down; never start a second copy.
                if runtime.pid != nil { continue }
                guard wantsToRun(runtime) else {
                    runtime.markStoppedIfIdle()
                    runtimes[id] = runtime
                    continue
                }
                if !permitted {
                    if runtime.state != .suspended {
                        runtime.markSuspended(reason: suspendReason)
                        runtimes[id] = runtime
                    }
                } else if runtime.spec.requiresNetwork && !networkUp {
                    runtime.markWaitingForNetwork()
                    runtimes[id] = runtime
                } else {
                    launch(id)
                }
            case .crashed, .failed:
                break
            }
        }
        notify()
    }

    private func launch(_ id: String) {
        guard var runtime = runtimes[id] else { return }
        let spec = runtime.spec
        let errors = spec.validationErrors()
        guard errors.isEmpty, let launcher = launcher(for: spec) else {
            let message = errors.isEmpty ? "no launcher for kind \(spec.kind.rawValue)" : errors.joined(separator: " ")
            logger.error("supervisor", "\(spec.name): cannot launch: \(message)")
            let action = runtime.markLaunchFailed(error: message, now: Date(), random: random)
            runtimes[id] = runtime
            schedule(id: id, action: action)
            return
        }

        instance[id, default: 0] += 1
        let token = instance[id]!
        let onExit: (ExitInfo.Reason, Int32) -> Void = { [weak self] reason, code in
            guard let self else { return }
            self.queue.async { self.handleExit(id: id, token: token, reason: reason, code: code) }
        }

        if let pid = launcher.adoptExisting(spec, onExit: onExit) {
            runtime.adopt(pid: pid, now: Date())
            runtimes[id] = runtime
            logger.info("supervisor", "\(spec.name): adopted running instance (pid \(pid))")
            return
        }

        runtime.markLaunching(now: Date())
        runtimes[id] = runtime
        logger.info("supervisor", "\(spec.name): launching")
        launcher.launch(spec, completion: { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard var r = self.runtimes[id], self.instance[id] == token else { return }
                switch result {
                case .success(let pid):
                    // The exit handler may already have run for a very short-lived process.
                    if r.state == .starting {
                        r.markRunning(pid: pid)
                        self.runtimes[id] = r
                        self.logger.info("supervisor", "\(spec.name): running (pid \(pid))")
                        self.writeRegistry()
                    }
                case .failure(let error):
                    self.logger.error("supervisor", "\(spec.name): launch failed: \(error.localizedDescription)")
                    let action = r.markLaunchFailed(error: error.localizedDescription, now: Date(), random: self.random)
                    self.runtimes[id] = r
                    self.schedule(id: id, action: action)
                }
                self.notify()
            }
        }, onExit: onExit)
    }

    private func handleExit(id: String, token: Int, reason: ExitInfo.Reason, code: Int32) {
        guard var runtime = runtimes[id] else {
            stopRequested.remove(id)
            return
        }
        guard instance[id] == token else { return }
        let requested = stopRequested.remove(id) != nil
        let info = ExitInfo(reason: reason, code: code, requested: requested)
        let action = runtime.handleExit(info, now: Date(), random: random)
        runtimes[id] = runtime
        let level: LogLevel = info.isCrash ? .error : .info
        logger.log(level, "supervisor", "\(runtime.spec.name) \(info.description)")
        writeRegistry()
        if requested {
            // Relaunch if still wanted (restart / config change), else leave stopped.
            reconcile()
        } else {
            schedule(id: id, action: action)
        }
        notify()
    }

    private func schedule(id: String, action: ExitAction) {
        guard let runtime = runtimes[id] else { return }
        switch action {
        case .none:
            break
        case .giveUp:
            logger.error("supervisor", "\(runtime.spec.name): \(runtime.note ?? "gave up restarting")")
        case .restart(let delay):
            restartToken[id, default: 0] += 1
            let token = restartToken[id]!
            logger.warning("supervisor", "\(runtime.spec.name): restarting in \(String(format: "%.1f", delay)) s (restart #\(runtime.restartCount))")
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard self.restartToken[id] == token, var r = self.runtimes[id], r.state == .restarting else { return }
                guard self.allowed.contains(r.spec.priority) else {
                    r.markSuspended(reason: self.suspendReason)
                    self.runtimes[id] = r
                    self.notify()
                    return
                }
                if r.spec.requiresNetwork && !self.networkUp {
                    r.markWaitingForNetwork()
                    self.runtimes[id] = r
                    self.notify()
                    return
                }
                self.launch(id)
                self.notify()
            }
        }
        notify()
    }

    private func writeRegistry() {
        guard let registryURL else { return }
        var records: [String: ProcessIdentity] = [:]
        for (id, runtime) in runtimes where runtime.spec.kind == .command && runtime.isActive {
            guard let pid = runtime.pid else { continue }
            records[id] = ProcessIdentity(pid: pid, startTime: inspector?.startTime(pid: pid))
        }
        if let data = try? JSONEncoder().encode(records) {
            try? FilePermissions.ensurePrivateDirectory(registryURL.deletingLastPathComponent())
            try? AtomicFile.write(data, to: registryURL)
        }
    }

    private func notify() {
        if let onChange { DispatchQueue.global(qos: .utility).async(execute: onChange) }
    }

    static func launchParametersChanged(_ a: ServiceSpec, _ b: ServiceSpec) -> Bool {
        a.kind != b.kind || a.path != b.path || a.arguments != b.arguments
            || a.workingDirectory != b.workingDirectory || a.environment != b.environment
    }
}
