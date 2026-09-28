import Foundation

/// Host services the monitor needs that are platform-specific (NSWorkspace on macOS).
public protocol TailscaleHostEnvironment: AnyObject {
    func isAppRunning(bundleID: String) -> Bool
    func launchApp(bundleID: String) -> Bool
}

/// Polls Tailscale at a relaxed interval while healthy and with exponential backoff while
/// not, and performs the limited recovery that is safe to automate.
public final class TailscaleMonitor {
    public var onChange: ((TailscaleStatus) -> Void)?

    private let queue = DispatchQueue(label: "com.macalwayson.tailscale")
    private let logger: EventLogger
    private let runner: CommandRunning
    private weak var environment: TailscaleHostEnvironment?
    private let locate: (String) -> TailscaleInstallation?
    private var settings: TailscaleSettings
    private var current = TailscaleStatus()
    private var backoff = BackoffTracker(base: 5, max: 300)
    private var generation = 0
    private var running = false
    private var lastUpAttempt: Date?

    public init(settings: TailscaleSettings, logger: EventLogger, runner: CommandRunning = ShellRunner.withUserContext(),
                environment: TailscaleHostEnvironment?,
                locate: @escaping (String) -> TailscaleInstallation? = { TailscaleCLI.locate(override: $0) }) {
        self.settings = settings
        self.logger = logger
        self.runner = runner
        self.environment = environment
        self.locate = locate
    }

    public var status: TailscaleStatus { queue.sync { current } }

    public func start() {
        queue.async { [self] in
            running = true
            scheduleCheck(after: 0)
        }
    }

    public func stop() {
        queue.sync {
            running = false
            generation += 1
        }
    }

    /// Check now (network path changed, wake from sleep, user request).
    public func poke() {
        queue.async { [self] in
            guard running else { return }
            backoff.reset()
            scheduleCheck(after: 0)
        }
    }

    public func update(settings newSettings: TailscaleSettings) {
        queue.async { [self] in
            settings = newSettings
            if running { scheduleCheck(after: 0) }
        }
    }

    /// Runs one check synchronously (used by one-shot diagnostics and tests).
    public func checkNow() -> TailscaleStatus {
        queue.sync {
            _ = performCheck()
            return current
        }
    }

    private func scheduleCheck(after delay: Double) {
        generation += 1
        let token = generation
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard running, token == generation else { return }
            let next = performCheck()
            scheduleCheck(after: next)
        }
    }

    /// Returns the delay until the next check.
    private func performCheck() -> Double {
        let now = Date()
        let previous = current
        var next = current
        next.lastCheckedAt = now
        defer {
            current = next
            if next != previous { onChange?(next) }
        }

        guard let install = locate(settings.cliPathOverride) else {
            next = TailscaleStatus()
            next.lastCheckedAt = now
            next.lastError = "Tailscale is not installed. Install it from https://tailscale.com/download/mac (Standalone or App Store) and sign in."
            if previous.installed { logger.warning("tailscale", "Tailscale CLI no longer found") }
            return 600
        }
        next.installed = true
        next.variant = install.variant
        next.cliPath = install.cliPath
        let cli = TailscaleCLI(installation: install, runner: runner)

        let parsed: TailscaleParsedStatus
        do {
            parsed = try cli.status()
        } catch {
            next.connected = false
            next.backendState = nil
            next.lastError = "Tailscale is not responding: \(error)"
            attemptAppRelaunch(install: install, status: &next)
            let delay = backoff.recordFailure()
            if previous.connected { logger.warning("tailscale", "Tailscale became unreachable: \(error)") }
            return delay
        }

        next.version = parsed.version
        next.backendState = parsed.backendState
        next.ipv4 = parsed.ipv4
        next.ipv6 = parsed.ipv6
        next.hostName = parsed.hostName
        next.dnsName = parsed.dnsName
        next.tailnetName = parsed.tailnetName
        next.magicDNSSuffix = parsed.magicDNSSuffix
        next.selfOnline = parsed.selfOnline
        next.peerCount = parsed.peerCount
        next.onlinePeerCount = parsed.onlinePeerCount
        next.health = parsed.health
        next.connected = parsed.isRunning && parsed.ipv4 != nil

        if next.connected {
            next.lastConnectedAt = now
            next.lastError = nil
            if !previous.connected {
                logger.info("tailscale", "Connected to tailnet as \(parsed.dnsName ?? parsed.hostName ?? "?") (\(parsed.ipv4 ?? "?"))")
            }
            backoff.reset()
            return Double(settings.statusIntervalSeconds)
        }

        next.lastError = TailscaleStatusParser.explain(backendState: parsed.backendState)
        if previous.connected {
            logger.warning("tailscale", "Disconnected from tailnet: \(next.lastError ?? "")")
        }

        switch parsed.backendState {
        case "NeedsLogin", "NeedsMachineAuth":
            // Requires a human; polling faster will not help.
            return max(Double(settings.statusIntervalSeconds), 300)
        case "Stopped":
            if settings.autoReconnect {
                attemptUp(cli: cli, status: &next, now: now)
            }
            return backoff.recordFailure()
        default:
            attemptAppRelaunch(install: install, status: &next)
            return backoff.recordFailure()
        }
    }

    private func attemptAppRelaunch(install: TailscaleInstallation, status: inout TailscaleStatus) {
        guard settings.autoReconnect, let bundleID = install.appBundleID, let environment else { return }
        guard !environment.isAppRunning(bundleID: bundleID) else { return }
        let launched = environment.launchApp(bundleID: bundleID)
        status.lastRecoveryAction = launched ? "Relaunched the Tailscale app" : "Failed to relaunch the Tailscale app"
        logger.warning("tailscale", status.lastRecoveryAction ?? "")
    }

    private func attemptUp(cli: TailscaleCLI, status: inout TailscaleStatus, now: Date) {
        if let last = lastUpAttempt, now.timeIntervalSince(last) < 30 { return }
        lastUpAttempt = now
        do {
            try cli.up()
            status.lastRecoveryAction = "Ran `tailscale up` (backend was Stopped)"
            logger.info("tailscale", "Backend was Stopped; ran `tailscale up`")
        } catch {
            status.lastRecoveryAction = "`tailscale up` failed: \(error)"
            logger.warning("tailscale", "`tailscale up` failed: \(error)")
        }
    }
}
