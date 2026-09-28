import AppKit
import Foundation
import AlwaysOnCore
import AlwaysOnPlatform

/// The LaunchAgent. Glues monitors, policy, supervisor, helper and servers together.
/// Mutable agent state is confined to `stateQueue`.
final class AgentController {
    static let refreshInterval: Double = 15
    static let helperLeaseSeconds: Double = 600
    static let helperRenewSeconds: Double = 120

    private let paths = UserPaths()
    private let configStore: ConfigStore
    private let logger: EventLogger
    private let startedAt = Date()
    private let runner = ShellRunner()
    private let stateQueue = DispatchQueue(label: "com.macalwayson.agent.state")
    private let probeQueue = DispatchQueue(label: "com.macalwayson.agent.probe", qos: .utility)

    private let assertions = AssertionManager()
    private let metrics = SystemMetrics()
    private let inspector = MacProcessInspector()
    private let supervisor: ServiceSupervisor
    private let tailscaleEnvironment = WorkspaceTailscaleEnvironment()
    private let tailscale: TailscaleMonitor
    private let helper = HelperClient()
    private var powerMonitor: PowerSourceMonitor?
    private var sleepMonitor: SleepWakeMonitor?
    private var pathMonitor: NetworkPathMonitor?
    private var controlServer: UnixSocketServer?
    private var webServer: StatusHTTPServer?
    private var timers: [DispatchSourceTimer] = []
    private var activity: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?

    // State (stateQueue only)
    private var config: AppConfiguration
    private var powerReading = PowerReading()
    private var power = PowerStatus()
    private var system = SystemStatus()
    private var network = NetworkStatus()
    private var remote = RemoteAccessStatus()
    private var helperStatus = HelperStatus()
    private var policyMemory = PolicyMemory()
    private var decision = PolicyDecision.inactive
    private var highCPUStreak = 0
    private var lastLidRequest: LidClosedRequest?
    private var lastLidRequestAt: Date?
    private var lastFirewallRequest: FirewallRequest?
    private var lastHelperError: String?
    private var networkBackoff = BackoffTracker(base: 30, max: 300)
    private var networkProbeGeneration = 0
    private var shuttingDown = false

    private let webAuthLock = NSLock()
    private var webAuthCache: [String: (login: String?, allowed: Bool, at: Date)] = [:]

    init() {
        configStore = ConfigStore(url: paths.configFile)
        var loadNotes: [String] = []
        let loaded: AppConfiguration
        do {
            let result = try configStore.load()
            loaded = result.configuration
            loadNotes = result.notes
        } catch {
            loaded = AppConfiguration()
            loadNotes = ["Could not read configuration (\(error)); using defaults."]
        }
        config = loaded
        logger = EventLogger(fileURL: paths.agentLog, level: loaded.logging.level,
                             maxFileBytes: loaded.logging.maxFileBytes, maxFiles: loaded.logging.maxFiles)
        supervisor = ServiceSupervisor(
            launchers: [CommandLauncher(paths: paths), AppLauncher()],
            inspector: inspector, logger: logger, registryURL: paths.pidRegistry
        )
        tailscale = TailscaleMonitor(settings: loaded.tailscale, logger: logger, environment: tailscaleEnvironment)
        for note in loadNotes { logger.warning("config", note) }
    }

    // MARK: Lifecycle

    func start() {
        logger.info("agent", "MacAlwaysOn agent \(Identifiers.version) starting (pid \(getpid()))")
        // Keep timers precise: opt out of App Nap without preventing idle sleep (the policy
        // decides that separately with IOPM assertions).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "MacAlwaysOn supervision")

        do {
            try FilePermissions.ensurePrivateDirectory(paths.supportDirectory)
            try FilePermissions.ensurePrivateDirectory(paths.runDirectory)
            try FilePermissions.ensurePrivateDirectory(paths.logsDirectory)
        } catch {
            logger.error("agent", "Cannot prepare directories: \(error)")
        }

        supervisor.cleanupOrphans()
        startControlServer()
        startPowerMonitoring()
        startNetworkMonitoring()

        tailscale.onChange = { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                self.updateWebServer()
                self.scheduleRemoteProbe()
            }
        }
        tailscale.start()

        stateQueue.sync {
            refreshPower()
            refreshHelperStatus()
            evaluatePolicy(reason: "startup")
            syncFirewall(force: true)
        }
        supervisor.apply(specs: config.services)
        scheduleNetworkProbe(after: 1)

        addTimer(interval: Self.refreshInterval) { [weak self] in self?.fastTick() }
        addTimer(interval: 60) { [weak self] in self?.slowTick() }
        addTimer(interval: Self.helperRenewSeconds) { [weak self] in
            guard let self else { return }
            self.stateQueue.async { self.syncHelper(force: false) }
        }
        logger.info("agent", "Agent started; \(config.services.count) service(s) configured")
    }

    func shutdown() {
        let alreadyStopping: Bool = stateQueue.sync {
            defer { shuttingDown = true }
            return shuttingDown
        }
        guard !alreadyStopping else { return }
        logger.info("agent", "Agent stopping")
        timers.forEach { $0.cancel() }
        controlServer?.stop()
        webServer?.stop()
        tailscale.stop()
        pathMonitor?.stop()
        powerMonitor?.stop()
        sleepMonitor?.stop()
        stateQueue.sync {
            // Never leave `disablesleep` behind when the agent is deliberately stopped.
            if helperStatus.state?.lidOverrideApplied == true {
                sendLidRequest(LidClosedRequest(enabled: false, allowOnBattery: false,
                                                batteryFloorPercent: config.power.helperBatteryFloorPercent,
                                                leaseSeconds: Self.helperLeaseSeconds))
            }
        }
        // Command services are our children; GUI apps are left running for the user.
        supervisor.stopAll(kinds: [.command])
        assertions.releaseAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        logger.info("agent", "Agent stopped")
        logger.flush()
    }

    private func addTimer(interval: Double, handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(Int(max(1, interval / 10))))
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }

    // MARK: Monitors

    private func startPowerMonitoring() {
        let monitor = PowerSourceMonitor { [weak self] in
            guard let self else { return }
            self.stateQueue.async {
                let before = self.powerReading
                self.refreshPower()
                if before.source != self.powerReading.source {
                    self.logger.info("power", "Power source changed to \(self.powerReading.source.rawValue)")
                }
                self.evaluatePolicy(reason: "power source changed")
            }
        }
        monitor.start()
        powerMonitor = monitor

        let sleep = SleepWakeMonitor { [weak self] event in self?.handleSleepEvent(event) }
        if !sleep.start() { logger.error("power", "IORegisterForSystemPower failed; sleep/wake times will not be recorded") }
        sleepMonitor = sleep

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                self.logger.info("power", "Thermal state changed to \(ThermalReader.current().rawValue)")
                self.evaluatePolicy(reason: "thermal state changed")
            }
        }
    }

    private func handleSleepEvent(_ event: SleepWakeMonitor.Event) {
        switch event {
        case .willSleep:
            // Called synchronously before sleep is acknowledged: record, do not block.
            let now = Date()
            stateQueue.async { self.power.lastSleepAt = now }
            logger.warning("power", "System is going to sleep; remote access will be unavailable until it wakes")
            logger.flush()
        case .willPowerOn:
            break
        case .didWake:
            stateQueue.async {
                let now = Date()
                self.power.lastWakeAt = now
                if let slept = self.power.lastSleepAt {
                    self.logger.info("power", "System woke after \(Formatting.duration(now.timeIntervalSince(slept))) asleep")
                } else {
                    self.logger.info("power", "System woke")
                }
                self.refreshPower()
                self.evaluatePolicy(reason: "wake")
                self.syncHelper(force: true)
                self.syncFirewall(force: true)
                self.updateWebServer()
            }
            tailscale.poke()
            scheduleNetworkProbe(after: 2)
        }
    }

    private func startNetworkMonitoring() {
        let monitor = NetworkPathMonitor { [weak self] info in
            guard let self else { return }
            self.stateQueue.async {
                let wasUp = self.network.pathSatisfied
                self.network.pathSatisfied = info.satisfied
                self.network.interfaces = info.interfaces
                self.network.primaryInterfaceType = info.primaryType
                self.network.lastChangeAt = Date()
                if wasUp != info.satisfied {
                    self.logger.log(info.satisfied ? .info : .warning, "network",
                                    info.satisfied ? "Network available (\(info.interfaces.joined(separator: ", ")))" : "Network lost")
                }
            }
            self.supervisor.setNetworkAvailable(info.satisfied)
            if info.satisfied {
                self.tailscale.poke()
                self.scheduleNetworkProbe(after: 2)
            }
        }
        monitor.start()
        pathMonitor = monitor
    }

    // MARK: Periodic work

    private func fastTick() {
        let sys = metrics.collect()
        supervisor.refreshMetrics()
        stateQueue.async {
            self.system = sys
            if self.powerReading.source == .battery, let cpu = sys.cpuPercent, cpu > Double(self.config.power.maxCPUPercentOnBattery) {
                self.highCPUStreak += 1
            } else {
                self.highCPUStreak = 0
            }
            let lidBefore = self.power.lid
            self.refreshPower()
            if lidBefore != self.power.lid, lidBefore != .unknown {
                self.logger.info("power", "Lid \(self.power.lid.rawValue)")
            }
            self.evaluatePolicy(reason: "periodic")
        }
    }

    private func slowTick() {
        let pmset = try? runner.run(SystemPaths.pmset, ["-g"], timeout: 10)
        stateQueue.async {
            if let pmset, pmset.succeeded {
                self.power.systemSleepDisabled = PMSetParser.sleepDisabled(pmset.stdout) ?? false
            }
            self.refreshHelperStatus()
            self.updateWebServer()
        }
        scheduleRemoteProbe()
    }

    // MARK: Power & policy (stateQueue)

    private func refreshPower() {
        powerReading = PowerSourceReader.read()
        power.source = powerReading.source
        power.hasBattery = powerReading.hasBattery
        power.batteryPercent = powerReading.percent
        power.isCharging = powerReading.isCharging
        power.isCharged = powerReading.isCharged
        power.timeRemainingMinutes = powerReading.timeToEmptyMinutes
        power.batteryHealth = powerReading.health
        if powerReading.hasBattery { power.cycleCount = PowerRegistry.batteryCycleCount() }
        power.lid = PowerRegistry.lidState()
        power.clamshellCausesSleep = PowerRegistry.clamshellCausesSleep()
    }

    private func evaluatePolicy(reason: String) {
        guard !shuttingDown else { return }
        let inputs = PolicyInputs(source: powerReading.source, batteryPercent: powerReading.percent,
                                  thermal: ThermalReader.current(), highCPUStreak: highCPUStreak,
                                  helperAvailable: helperStatus.reachable)
        let next = PowerPolicy.evaluate(inputs, settings: config.power, memory: &policyMemory)

        let wantedAssertions: [(AssertionManager.Kind, Bool)] = [
            (.preventIdleSleep, next.preventIdleSleep),
            (.preventSystemSleep, next.preventSystemSleep),
            (.preventDisplaySleep, next.preventDisplaySleep),
        ]
        for (kind, wanted) in wantedAssertions {
            if let error = assertions.set(kind, held: wanted) { logger.error("power", error) }
        }
        power.assertions = assertions.status

        let modeChanged = next.mode != decision.mode
        let lidChanged = next.lidClosedOverride != decision.lidClosedOverride
        let prioritiesChanged = next.allowedPriorities != decision.allowedPriorities
        if modeChanged || lidChanged || prioritiesChanged {
            logger.info("policy", "Mode \(next.mode.rawValue) (\(reason)): \(next.reasons.joined(separator: " "))")
        }
        decision = next
        power.policy = next
        supervisor.setAllowedPriorities(next.allowedPriorities, reason: next.reasons.first ?? next.mode.rawValue)
        if lidChanged { syncHelper(force: true) }
    }

    // MARK: Helper (stateQueue)

    private func refreshHelperStatus() {
        let wasReachable = helperStatus.reachable
        helperStatus = helper.status()
        if let state = helperStatus.state {
            power.systemSleepDisabled = state.systemSleepDisabled ?? power.systemSleepDisabled
            remote.firewallRestricted = state.firewallActive
        } else if !helperStatus.installed {
            remote.firewallRestricted = nil
        }
        if wasReachable != helperStatus.reachable {
            logger.info("helper", helperStatus.reachable ? "Privileged helper reachable" : "Privileged helper not reachable")
            evaluatePolicy(reason: "helper availability changed")
            syncFirewall(force: true)
        }
    }

    private func syncHelper(force: Bool) {
        guard helper.isInstalled else { return }
        let request = LidClosedRequest(enabled: decision.lidClosedOverride,
                                       allowOnBattery: config.power.lidClosedOnBattery,
                                       batteryFloorPercent: config.power.helperBatteryFloorPercent,
                                       leaseSeconds: Self.helperLeaseSeconds)
        let due = lastLidRequestAt.map { Date().timeIntervalSince($0) >= Self.helperRenewSeconds - 5 } ?? true
        // Renew the lease while enabled; send changes immediately.
        guard force || request != lastLidRequest || (request.enabled && due) else { return }
        // Nothing to disable if we never enabled it and the helper has nothing applied.
        if !request.enabled && lastLidRequest == nil && helperStatus.state?.lidOverrideApplied != true { return }
        sendLidRequest(request)
    }

    private func sendLidRequest(_ request: LidClosedRequest) {
        do {
            let response = try helper.send(HelperRequest(command: .setLidClosedOperation, lidClosed: request))
            lastLidRequest = request
            lastLidRequestAt = Date()
            if let state = response.state {
                helperStatus.state = state
                helperStatus.reachable = true
                power.systemSleepDisabled = state.systemSleepDisabled
            }
            if response.ok {
                lastHelperError = nil
            } else if response.error != lastHelperError {
                lastHelperError = response.error
                logger.warning("helper", "Lid-closed request not applied: \(response.error ?? "unknown")")
            }
        } catch {
            let message = "Helper unreachable: \(error)"
            if message != lastHelperError {
                lastHelperError = message
                logger.warning("helper", message)
            }
            helperStatus.reachable = false
        }
    }

    private func syncFirewall(force: Bool) {
        guard helper.isInstalled else { return }
        let ra = config.remoteAccess
        let request = FirewallRequest(enabled: ra.restrictPortsToTailnet, tcpPorts: ra.restrictedTCPPorts, udpPorts: ra.restrictedUDPPorts)
        guard force || request != lastFirewallRequest else { return }
        // Avoid touching pf at all if the feature was never enabled.
        if !request.enabled && lastFirewallRequest == nil && helperStatus.state?.firewallEnabled != true { return }
        do {
            let response = try helper.send(HelperRequest(command: .setFirewall, firewall: request))
            lastFirewallRequest = request
            if let state = response.state {
                helperStatus.state = state
                remote.firewallRestricted = state.firewallActive
            }
            if !response.ok { logger.error("helper", "Firewall request failed: \(response.error ?? "unknown")") }
        } catch {
            logger.warning("helper", "Firewall request could not reach helper: \(error)")
        }
    }

    // MARK: Network probes

    private func scheduleNetworkProbe(after delay: Double) {
        stateQueue.async { [self] in
            self.networkProbeGeneration += 1
            let generation = self.networkProbeGeneration
            self.probeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let current = self.stateQueue.sync { self.networkProbeGeneration }
                guard current == generation else { return }
                let ok = self.runNetworkProbe()
                let next: Double = self.stateQueue.sync {
                    if ok {
                        self.networkBackoff.reset()
                        return Double(self.config.diagnostics.intervalSeconds)
                    }
                    return self.networkBackoff.recordFailure()
                }
                self.scheduleNetworkProbe(after: next)
            }
        }
    }

    /// Runs DNS / Internet / gateway checks off the state queue. Returns overall success.
    @discardableResult
    private func runNetworkProbe() -> Bool {
        let settings = stateQueue.sync { config.diagnostics }
        let dns = DNSProbe.resolveIPv4(settings.dnsProbeHost, timeout: 5)
        var internet: ProbeResult = .failed("DNS failed")
        let target = settings.internetProbeHost == settings.dnsProbeHost ? dns : DNSProbe.resolveIPv4(settings.internetProbeHost, timeout: 5)
        if let ip = target.addresses.first {
            internet = TCPProbe.connect(host: ip, port: settings.internetProbePort, timeout: 5)
        }
        let route = try? runner.run(SystemPaths.route, ["-n", "get", "default"], timeout: 5)
        let gateway = route.flatMap { $0.succeeded ? RouteParser.defaultGateway($0.stdout) : nil }
        let local = InterfaceAddresses.localIPv4(from: InterfaceAddresses.current())

        return stateQueue.sync {
            let hadInternet = network.internetReachable
            network.dnsWorking = dns.succeeded
            network.internetReachable = internet.succeeded
            network.gateway = gateway
            network.localIPv4 = local
            network.lastCheckedAt = Date()
            network.detail = dns.error ?? (internet.succeeded ? nil : "Internet probe to \(settings.internetProbeHost):\(settings.internetProbePort): \(internet.summary)")
            if hadInternet != network.internetReachable {
                logger.log(internet.succeeded ? .info : .warning, "network",
                           internet.succeeded ? "Internet reachable" : "Internet unreachable: \(network.detail ?? "")")
            }
            return dns.succeeded && internet.succeeded
        }
    }

    private func scheduleRemoteProbe() {
        probeQueue.async { [weak self] in self?.runRemoteProbe() }
    }

    private func runRemoteProbe() {
        let ts = tailscale.status
        let settings = stateQueue.sync { config.remoteAccess }
        var ssh = EndpointStatus(available: nil, detail: "Not checked (disabled in settings)")
        var vnc = EndpointStatus(available: nil, detail: "Not checked (disabled in settings)")
        if let ip = ts.ipv4, ts.connected {
            if settings.probeSSH { ssh = Self.endpoint(ip: ip, port: 22, name: "SSH (Remote Login)") }
            if settings.probeScreenSharing { vnc = Self.endpoint(ip: ip, port: 5900, name: "Screen Sharing") }
        } else {
            let why = "Unavailable: Tailscale is not connected"
            ssh = EndpointStatus(available: false, detail: why)
            vnc = EndpointStatus(available: false, detail: why)
        }
        stateQueue.async {
            self.remote.tailscaleIP = ts.ipv4
            self.remote.tailscaleHost = ts.dnsName ?? ts.hostName
            self.remote.ssh = ssh
            self.remote.screenSharing = vnc
            self.remote.lastCheckedAt = Date()
        }
    }

    private static func endpoint(ip: String, port: Int, name: String) -> EndpointStatus {
        let address = "\(ip):\(port)"
        switch TCPProbe.connect(host: ip, port: port, timeout: 2) {
        case .success(let ms):
            return EndpointStatus(available: true, address: address, detail: "\(name) is accepting connections on \(address) (\(ms) ms)")
        case .refused:
            return EndpointStatus(available: false, address: address, detail: "\(name) is off: nothing is listening on port \(port)")
        case .timedOut:
            return EndpointStatus(available: false, address: address, detail: "\(name) did not answer on \(address) (filtered by a firewall?)")
        case .failed(let message):
            return EndpointStatus(available: false, address: address, detail: "\(name) check failed: \(message)")
        }
    }

    // MARK: Web dashboard (stateQueue)

    private func updateWebServer() {
        let ts = tailscale.status
        let settings = config.remoteAccess
        guard !shuttingDown, settings.webDashboardEnabled, ts.connected, let ip = ts.ipv4, IPv4Address(ip)?.isTailscale == true else {
            if let server = webServer {
                server.stop()
                webServer = nil
                logger.info("web", "Web dashboard stopped (Tailscale not connected or dashboard disabled)")
            }
            remote.webDashboard = EndpointStatus(available: settings.webDashboardEnabled ? false : nil,
                                                 detail: settings.webDashboardEnabled ? "Waiting for Tailscale to connect" : "Disabled in settings")
            return
        }
        if let server = webServer, server.bindAddress == ip, server.port == settings.webDashboardPort, server.isRunning {
            return
        }
        webServer?.stop()
        let server = StatusHTTPServer(bindAddress: ip, port: settings.webDashboardPort,
                                      authorize: { [weak self] peer in self?.authorizeWebPeer(peer) ?? false },
                                      router: { [weak self] request, peer in
                                          self?.route(request, peer: peer) ?? .text(503, "Service Unavailable", "Agent stopping")
                                      })
        do {
            try server.start()
            webServer = server
            let url = "http://\(ts.dnsName ?? ip):\(settings.webDashboardPort)/"
            remote.webDashboard = EndpointStatus(available: true, address: "\(ip):\(settings.webDashboardPort)", detail: "Serving read-only status at \(url) (tailnet only)")
            logger.info("web", "Web dashboard listening on \(ip):\(settings.webDashboardPort) (Tailscale interface only)")
        } catch {
            webServer = nil
            remote.webDashboard = EndpointStatus(available: false, detail: "Could not bind \(ip):\(settings.webDashboardPort): \(error)")
            logger.error("web", "Web dashboard bind failed: \(error)")
        }
    }

    private func authorizeWebPeer(_ peer: String) -> Bool {
        guard let address = IPv4Address(peer), address.isTailscale else { return false }
        let allowed = stateQueue.sync { config.remoteAccess.webDashboardAllowedLogins }
        guard !allowed.isEmpty else { return true }
        return webLogin(for: peer, allowed: allowed).allowed
    }

    private func webLogin(for peer: String, allowed: [String]) -> (login: String?, allowed: Bool) {
        webAuthLock.lock()
        if let cached = webAuthCache[peer], Date().timeIntervalSince(cached.at) < 300 {
            webAuthLock.unlock()
            return (cached.login, cached.allowed)
        }
        webAuthLock.unlock()
        var login: String?
        if let install = TailscaleCLI.locate(override: stateQueue.sync { config.tailscale.cliPathOverride }) {
            login = TailscaleCLI(installation: install, runner: runner).whoisLogin(ip: peer)
        }
        let ok = login.map { name in allowed.contains { $0.caseInsensitiveCompare(name) == .orderedSame } } ?? false
        webAuthLock.lock()
        webAuthCache[peer] = (login, ok, Date())
        webAuthLock.unlock()
        if !ok { logger.warning("web", "Denied web dashboard access to \(peer) (\(login ?? "unknown user"))") }
        return (login, ok)
    }

    private func route(_ request: HTTPRequestLine, peer: String) -> HTTPResponse {
        switch request.path {
        case "/":
            webAuthLock.lock()
            let viewer = webAuthCache[peer]?.login
            webAuthLock.unlock()
            let html = StatusPage.render(snapshot(), viewer: viewer)
            return HTTPResponse(status: 200, reason: "OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        case "/api/status":
            let data = (try? JSONCoding.encoder(pretty: true).encode(snapshot())) ?? Data("{}".utf8)
            return HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: data)
        case "/healthz":
            return .text(200, "OK", snapshot().overall.level.rawValue)
        default:
            return .text(404, "Not Found", "Not Found")
        }
    }

    // MARK: Snapshot & diagnostics

    func snapshot() -> StatusSnapshot {
        let services = supervisor.statuses()
        let ts = tailscale.status
        let selfSample = inspector.sample(pid: getpid())
        return stateQueue.sync {
            var s = StatusSnapshot(generatedAt: Date(), refreshIntervalSeconds: Self.refreshInterval,
                                   agent: AgentInfo(version: Identifiers.version, pid: getpid(), startedAt: startedAt,
                                                    cpuPercent: selfSample?.cpuPercent, residentBytes: selfSample?.memoryBytes))
            s.system = system
            s.power = power
            s.power.assertions = assertions.status
            s.network = network
            s.tailscale = ts
            s.services = services
            s.remoteAccess = remote
            if s.remoteAccess.tailscaleIP == nil { s.remoteAccess.tailscaleIP = ts.ipv4 }
            if s.remoteAccess.tailscaleHost == nil { s.remoteAccess.tailscaleHost = ts.dnsName ?? ts.hostName }
            s.helper = helperStatus
            s.overall = HealthSummarizer.summarize(s)
            return s
        }
    }

    func runDiagnostics() -> DiagnosticsReport {
        runNetworkProbe()
        _ = tailscale.checkNow()
        runRemoteProbe()
        stateQueue.sync {
            refreshPower()
            refreshHelperStatus()
        }
        let pmset = try? runner.run(SystemPaths.pmset, ["-g"], timeout: 10)
        let netstat = try? runner.run(SystemPaths.netstat, ["-an", "-p", "tcp"], timeout: 10)
        let pmSettings = pmset.flatMap { $0.succeeded ? PMSetParser.settings($0.stdout) : nil }
        if let pmset, pmset.succeeded {
            stateQueue.sync { power.systemSleepDisabled = PMSetParser.sleepDisabled(pmset.stdout) ?? false }
        }
        let settings = stateQueue.sync { config.remoteAccess }
        let context = DiagnosticsContext(
            listeners: netstat.flatMap { $0.succeeded ? NetstatParser.listeners($0.stdout) : nil },
            pmsetSettings: pmSettings,
            restrictedTCPPorts: settings.restrictPortsToTailnet ? settings.restrictedTCPPorts : [],
            webDashboardEnabled: settings.webDashboardEnabled
        )
        let report = DiagnosticsEngine.evaluate(snapshot(), context: context)
        let failures = report.checks.filter { $0.outcome == .fail }.map(\.title)
        logger.info("diagnostics", "Diagnostics run: \(report.checks.count) checks, \(failures.count) failing\(failures.isEmpty ? "" : " (\(failures.joined(separator: ", ")))")")
        return report
    }

    // MARK: Control socket

    private func startControlServer() {
        let uid = getuid()
        let server = UnixSocketServer(path: paths.agentSocket.path, permissions: 0o600,
                                      authorize: { $0 == uid },
                                      handler: { [weak self] data, _ in
                                          guard let self else { return Data() }
                                          let response: AgentResponse
                                          do {
                                              let request = try JSONCoding.decoder().decode(AgentRequest.self, from: data)
                                              response = self.handle(request)
                                          } catch {
                                              response = .failure("Malformed request: \(error)")
                                          }
                                          return (try? JSONCoding.encoder().encode(response)) ?? Data()
                                      })
        do {
            try server.start()
            controlServer = server
        } catch {
            logger.error("agent", "Control socket unavailable at \(paths.agentSocket.path): \(error). The app cannot talk to the agent.")
        }
    }

    private func handle(_ request: AgentRequest) -> AgentResponse {
        switch request.command {
        case .status:
            return AgentResponse(ok: true, snapshot: snapshot())
        case .reloadConfig:
            if let error = reloadConfiguration() { return .failure(error) }
            return AgentResponse(ok: true, snapshot: snapshot())
        case .startService, .stopService, .restartService:
            guard let id = request.serviceID else { return .failure("serviceID is required") }
            let error: String?
            switch request.command {
            case .startService: error = supervisor.start(id: id)
            case .stopService: error = supervisor.stop(id: id)
            default: error = supervisor.restart(id: id)
            }
            if let error { return .failure(error) }
            return AgentResponse(ok: true, snapshot: snapshot())
        case .runDiagnostics:
            return AgentResponse(ok: true, snapshot: snapshot(), diagnostics: runDiagnostics())
        case .recentLogs:
            return AgentResponse(ok: true, logs: logger.recentEntries(limit: min(max(request.limit ?? 200, 1), 500)))
        }
    }

    private func reloadConfiguration() -> String? {
        let result: ConfigLoadResult
        do {
            result = try configStore.load()
        } catch {
            return "Could not load configuration: \(error)"
        }
        for note in result.notes { logger.warning("config", note) }
        let newConfig = result.configuration
        logger.setLevel(newConfig.logging.level)
        stateQueue.sync {
            let intervalChanged = newConfig.diagnostics != config.diagnostics
            config = newConfig
            evaluatePolicy(reason: "configuration reloaded")
            syncHelper(force: true)
            syncFirewall(force: false)
            updateWebServer()
            if intervalChanged { networkBackoff.reset() }
        }
        tailscale.update(settings: newConfig.tailscale)
        supervisor.apply(specs: newConfig.services)
        scheduleNetworkProbe(after: 1)
        scheduleRemoteProbe()
        logger.info("config", "Configuration reloaded (\(newConfig.services.count) services)")
        return nil
    }
}
