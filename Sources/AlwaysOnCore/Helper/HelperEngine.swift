import Foundation

/// The privileged helper's logic, separated from process/socket plumbing so it can be
/// tested with a fake command runner. Every state change is serialized on one queue.
///
/// Principles:
///  * It only reverts what it applied itself (`lidOverrideApplied`); a `SleepDisabled`
///    setting made by the administrator by hand is left alone.
///  * The lid-closed override lives on a lease the agent must keep renewing.
///  * Battery floor and thermal limits are enforced here, independently of the agent.
public final class HelperEngine {
    private let queue = DispatchQueue(label: "com.macalwayson.helper.engine")
    private let stateURL: URL?
    private let runner: CommandRunning
    private let powerFacts: () -> HelperPowerFacts
    private let logger: EventLogger
    private let now: () -> Date
    private var state = HelperState()

    public init(stateURL: URL?, runner: CommandRunning, logger: EventLogger,
                powerFacts: @escaping () -> HelperPowerFacts, now: @escaping () -> Date = Date.init) {
        self.stateURL = stateURL
        self.runner = runner
        self.logger = logger
        self.powerFacts = powerFacts
        self.now = now
        if let stateURL, let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONCoding.decoder().decode(HelperState.self, from: data) {
            state = saved
        }
    }

    public var currentState: HelperState { queue.sync { state } }

    // MARK: Lifecycle

    /// Called at helper start (boot): pf anchors do not survive a reboot, and a lease may
    /// have expired while the helper was not running.
    public func startupRecovery() {
        queue.sync {
            state.pfToken = nil
            state.firewallActive = false
            if state.firewallEnabled {
                do { try applyFirewall() } catch { record(error: "firewall restore failed: \(error)") }
            }
            evaluateSafety()
            refreshSleepDisabled()
            persist()
        }
    }

    /// Periodic / event-driven safety evaluation.
    public func safetyCheck() {
        queue.sync {
            evaluateSafety()
            persist()
        }
    }

    /// Used by the uninstaller: undo everything this helper applied.
    public func revertAll() {
        queue.sync {
            if state.lidOverrideApplied { revertLidOverride(reason: "uninstall / revert-all") }
            state.lidOverrideRequested = false
            if state.firewallEnabled || state.firewallActive { removeFirewall() }
            state.firewallEnabled = false
            persist()
        }
    }

    /// Called when the helper itself is stopped: nobody would enforce the lease any more,
    /// so the lid-closed override is withdrawn. The agent re-requests it after a restart.
    public func releaseLidOverride(reason: String) {
        queue.sync {
            if state.lidOverrideApplied { revertLidOverride(reason: reason) }
            persist()
        }
    }

    // MARK: Requests

    public func handle(_ request: HelperRequest) -> HelperResponse {
        queue.sync {
            do {
                switch request.command {
                case .status:
                    refreshSleepDisabled()
                case .setLidClosedOperation:
                    guard let lid = request.lidClosed else { throw HelperValidation.Failure.missingPayload }
                    try HelperValidation.validate(lid)
                    try setLidClosed(lid)
                case .setFirewall:
                    guard let fw = request.firewall else { throw HelperValidation.Failure.missingPayload }
                    try HelperValidation.validate(fw)
                    try setFirewall(fw)
                }
                persist()
                return HelperResponse(ok: true, state: state)
            } catch {
                record(error: "\(error)")
                persist()
                return HelperResponse(ok: false, error: "\(error)", state: state)
            }
        }
    }

    // MARK: Lid-closed override (queue only)

    private func setLidClosed(_ request: LidClosedRequest) throws {
        state.allowOnBattery = request.allowOnBattery
        state.batteryFloorPercent = request.batteryFloorPercent
        guard request.enabled else {
            state.lidOverrideRequested = false
            state.leaseExpiresAt = nil
            if state.lidOverrideApplied { revertLidOverride(reason: "disabled by agent") }
            return
        }
        if let refusal = HelperSafety.mayApply(request: request, facts: powerFacts()) {
            state.lidOverrideRequested = false
            if state.lidOverrideApplied { revertLidOverride(reason: refusal) }
            throw HelperError.refused(refusal)
        }
        state.lidOverrideRequested = true
        state.leaseExpiresAt = now().addingTimeInterval(request.leaseSeconds)
        if !state.lidOverrideApplied {
            try runPMSet(disableSleep: true)
            state.lidOverrideApplied = true
            logger.warning("helper", "Applied pmset disablesleep 1 (lid-closed operation); lease \(Int(request.leaseSeconds)) s")
        }
        refreshSleepDisabled()
    }

    private func evaluateSafety() {
        if let reason = HelperSafety.revertReason(state: state, facts: powerFacts(), now: now()) {
            revertLidOverride(reason: reason)
        }
    }

    private func revertLidOverride(reason: String) {
        do {
            try runPMSet(disableSleep: false)
            state.lidOverrideApplied = false
            state.lidOverrideRequested = false
            state.leaseExpiresAt = nil
            state.lastRevertReason = reason
            state.lastRevertAt = now()
            logger.warning("helper", "Reverted pmset disablesleep 0: \(reason)")
        } catch {
            record(error: "failed to revert disablesleep: \(error)")
        }
        refreshSleepDisabled()
    }

    private func runPMSet(disableSleep: Bool) throws {
        let result = try runner.run(SystemPaths.pmset, ["-a", "disablesleep", disableSleep ? "1" : "0"], stdin: nil, timeout: 15)
        guard result.succeeded else {
            throw HelperError.commandFailed("pmset: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func refreshSleepDisabled() {
        if let result = try? runner.run(SystemPaths.pmset, ["-g"], stdin: nil, timeout: 10), result.succeeded {
            // pmset only prints SleepDisabled when it is set; absence means 0.
            state.systemSleepDisabled = PMSetParser.sleepDisabled(result.stdout) ?? false
        }
    }

    // MARK: Firewall (queue only)

    private func setFirewall(_ request: FirewallRequest) throws {
        let tcp = Array(Set(request.tcpPorts)).sorted()
        let udp = Array(Set(request.udpPorts)).sorted()
        if request.enabled && !(tcp.isEmpty && udp.isEmpty) {
            let changed = tcp != state.firewallTCPPorts || udp != state.firewallUDPPorts || !state.firewallActive
            state.firewallEnabled = true
            state.firewallTCPPorts = tcp
            state.firewallUDPPorts = udp
            if changed { try applyFirewall() }
        } else {
            state.firewallEnabled = false
            if state.firewallActive || state.pfToken != nil { removeFirewall() }
        }
    }

    private func applyFirewall() throws {
        let rules = try runner.run(SystemPaths.pfctl, ["-s", "rules"], stdin: nil, timeout: 15)
        if !PFCtlParser.hasAppleAnchor(rules.stdout) {
            // Load the unmodified system ruleset, which declares `anchor "com.apple/*"`.
            _ = try runner.run(SystemPaths.pfctl, ["-f", "/etc/pf.conf"], stdin: nil, timeout: 15)
            let again = try runner.run(SystemPaths.pfctl, ["-s", "rules"], stdin: nil, timeout: 15)
            guard PFCtlParser.hasAppleAnchor(again.stdout) else {
                throw HelperError.commandFailed("/etc/pf.conf does not evaluate the com.apple/* anchor; refusing to modify system files")
            }
        }
        let text = PFRules.render(tcpPorts: state.firewallTCPPorts, udpPorts: state.firewallUDPPorts)
        let load = try runner.run(SystemPaths.pfctl, ["-a", PFRules.anchorName, "-f", "-"], stdin: Data(text.utf8), timeout: 15)
        guard load.succeeded else {
            throw HelperError.commandFailed("pfctl load: \(load.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if state.pfToken == nil {
            let enable = try runner.run(SystemPaths.pfctl, ["-E"], stdin: nil, timeout: 15)
            state.pfToken = PFCtlParser.enableToken(enable.stderr + "\n" + enable.stdout)
            if state.pfToken == nil {
                throw HelperError.commandFailed("pfctl -E returned no reference token: \(enable.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        let verify = try runner.run(SystemPaths.pfctl, ["-a", PFRules.anchorName, "-s", "rules"], stdin: nil, timeout: 15)
        state.firewallActive = verify.succeeded && verify.stdout.contains("block drop in quick")
        guard state.firewallActive else { throw HelperError.commandFailed("pf anchor did not load") }
        logger.info("helper", "pf anchor \(PFRules.anchorName) active for tcp \(state.firewallTCPPorts) udp \(state.firewallUDPPorts)")
    }

    private func removeFirewall() {
        _ = try? runner.run(SystemPaths.pfctl, ["-a", PFRules.anchorName, "-F", "all"], stdin: nil, timeout: 15)
        if let token = state.pfToken {
            _ = try? runner.run(SystemPaths.pfctl, ["-X", token], stdin: nil, timeout: 15)
        }
        state.pfToken = nil
        state.firewallActive = false
        logger.info("helper", "pf anchor \(PFRules.anchorName) removed")
    }

    // MARK: Persistence

    private func record(error: String) {
        state.lastError = error
        logger.error("helper", error)
    }

    private func persist() {
        guard let stateURL, let data = try? JSONCoding.encoder(pretty: true).encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        try? AtomicFile.write(data, to: stateURL, permissions: 0o644)
    }
}

public enum HelperError: Error, CustomStringConvertible {
    case refused(String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .refused(let reason): return "refused: \(reason)"
        case .commandFailed(let message): return message
        }
    }
}

/// Parses the root-owned allow-list of UIDs that may talk to the helper.
public enum AuthorizedUIDs {
    public static func parse(_ text: String) -> Set<UInt32> {
        var result = Set<UInt32>()
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let uid = UInt32(trimmed) else { continue }
            result.insert(uid)
        }
        return result
    }
}
