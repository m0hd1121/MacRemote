import Foundation

public enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case power, network, tailscale, remoteAccess, services, security

    public var displayName: String {
        switch self {
        case .power: return "Power"
        case .network: return "Network"
        case .tailscale: return "Tailscale"
        case .remoteAccess: return "Remote Access"
        case .services: return "Services"
        case .security: return "Security"
        }
    }
}

public enum DiagnosticOutcome: String, Codable, Sendable {
    case pass, info, warning, fail
}

public struct DiagnosticCheck: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var category: DiagnosticCategory
    public var title: String
    public var outcome: DiagnosticOutcome
    /// Plain-language explanation of the current state and *why*.
    public var detail: String
    /// What the user can do about it, if anything.
    public var remedy: String?

    public init(id: String, category: DiagnosticCategory, title: String, outcome: DiagnosticOutcome,
                detail: String, remedy: String? = nil) {
        self.id = id
        self.category = category
        self.title = title
        self.outcome = outcome
        self.detail = detail
        self.remedy = remedy
    }
}

public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var checks: [DiagnosticCheck]

    public init(generatedAt: Date, checks: [DiagnosticCheck]) {
        self.generatedAt = generatedAt
        self.checks = checks
    }

    public var worstOutcome: DiagnosticOutcome {
        if checks.contains(where: { $0.outcome == .fail }) { return .fail }
        if checks.contains(where: { $0.outcome == .warning }) { return .warning }
        return .pass
    }
}

/// Extra facts gathered only when diagnostics run (too expensive for every snapshot).
public struct DiagnosticsContext: Sendable {
    public var listeners: [ListeningSocket]?
    public var pmsetSettings: [String: String]?
    public var restrictedTCPPorts: [Int]
    public var webDashboardEnabled: Bool

    public init(listeners: [ListeningSocket]? = nil, pmsetSettings: [String: String]? = nil,
                restrictedTCPPorts: [Int] = [], webDashboardEnabled: Bool = true) {
        self.listeners = listeners
        self.pmsetSettings = pmsetSettings
        self.restrictedTCPPorts = restrictedTCPPorts
        self.webDashboardEnabled = webDashboardEnabled
    }
}

public enum DiagnosticsEngine {
    public static let sharingSettingsHint = "System Settings → General → Sharing"

    public static func evaluate(_ s: StatusSnapshot, context: DiagnosticsContext, now: Date = Date()) -> DiagnosticsReport {
        var checks: [DiagnosticCheck] = []
        checks += powerChecks(s, context: context, now: now)
        checks += networkChecks(s)
        checks += tailscaleChecks(s)
        checks += remoteAccessChecks(s, context: context)
        checks += serviceChecks(s)
        checks += securityChecks(s, context: context)
        return DiagnosticsReport(generatedAt: now, checks: checks)
    }

    /// Used by clients (GUI, web page) when the agent has stopped reporting.
    public static func agentUnavailableCheck(lastSnapshot: StatusSnapshot?, now: Date = Date()) -> DiagnosticCheck {
        var detail = "The background agent is not responding, so nothing is being supervised and Always-On is not being enforced."
        if let last = lastSnapshot {
            detail += " Its last report was \(Formatting.duration(now.timeIntervalSince(last.generatedAt))) ago."
        }
        return DiagnosticCheck(id: "agent.unavailable", category: .power, title: "Background agent", outcome: .fail,
                               detail: detail,
                               remedy: "Run: launchctl kickstart -k gui/$(id -u)/\(Identifiers.agentLabel)  — or reinstall with Scripts/install.sh.")
    }

    // MARK: Power

    static func powerChecks(_ s: StatusSnapshot, context: DiagnosticsContext, now: Date) -> [DiagnosticCheck] {
        var checks: [DiagnosticCheck] = []
        let p = s.power
        let policy = p.policy

        var awakeDetail = "The agent is running and reporting, so the Mac is awake right now."
        if let sleep = p.lastSleepAt, let wake = p.lastWakeAt, wake >= sleep {
            awakeDetail += " It last slept from \(Formatting.time(sleep)) to \(Formatting.time(wake)) (\(Formatting.duration(wake.timeIntervalSince(sleep)))); remote access was unavailable during that time because macOS had entered system sleep."
        }
        checks.append(DiagnosticCheck(id: "power.awake", category: .power, title: "Is the Mac currently awake?", outcome: .pass, detail: awakeDetail))

        let sourceText: String
        switch p.source {
        case .ac: sourceText = "Running on AC power."
        case .ups: sourceText = "Running on UPS power."
        case .battery: sourceText = "Running on battery (\(p.batteryPercent.map { "\($0)%" } ?? "unknown level"))."
        case .unknown: sourceText = "Power source could not be determined."
        }
        checks.append(DiagnosticCheck(id: "power.source", category: .power, title: "Is AC connected?",
                                      outcome: p.source == .battery ? .info : (p.source == .unknown ? .warning : .pass),
                                      detail: sourceText))

        if policy.preventIdleSleep && !p.assertions.idleSleepPrevented {
            checks.append(DiagnosticCheck(id: "power.assertions", category: .power, title: "Are sleep assertions active?", outcome: .fail,
                                          detail: "The policy requires an idle-sleep assertion but it is not held. The Mac may idle-sleep.",
                                          remedy: "Check the agent log for IOPMAssertionCreateWithName errors, then restart the agent."))
        } else if policy.preventIdleSleep {
            var held = ["idle sleep prevented"]
            if p.assertions.systemSleepPrevented { held.append("system sleep prevented (AC)") }
            if p.assertions.displaySleepPrevented { held.append("display kept on") }
            checks.append(DiagnosticCheck(id: "power.assertions", category: .power, title: "Are sleep assertions active?", outcome: .pass,
                                          detail: "Yes: " + held.joined(separator: ", ") + "."))
        } else {
            checks.append(DiagnosticCheck(id: "power.assertions", category: .power, title: "Are sleep assertions active?", outcome: .info,
                                          detail: "No assertions are held because the current mode is \(policy.mode.rawValue): " + policy.reasons.joined(separator: " ")))
        }

        let lidText: String
        switch p.lid {
        case .open: lidText = "The lid is open."
        case .closed: lidText = "The lid is closed."
        case .notPresent: lidText = "This Mac has no lid (desktop)."
        case .unknown: lidText = "Lid state is not available."
        }
        checks.append(DiagnosticCheck(id: "power.lid", category: .power, title: "Is the lid closed?", outcome: .info, detail: lidText))
        checks.append(lidCapability(s))

        if policy.mode == .relaxed || policy.mode == .batterySaver {
            checks.append(DiagnosticCheck(id: "power.policy", category: .power, title: "Battery / thermal policy", outcome: .warning,
                                          detail: policy.reasons.joined(separator: " ")))
        } else {
            checks.append(DiagnosticCheck(id: "power.policy", category: .power, title: "Always-On policy",
                                          outcome: policy.mode == .off ? .info : .pass,
                                          detail: policy.reasons.joined(separator: " ")))
        }

        switch s.system.thermal {
        case .critical:
            checks.append(DiagnosticCheck(id: "power.thermal", category: .power, title: "Thermal state", outcome: .fail,
                                          detail: "Thermal state is critical. macOS is throttling heavily and may sleep; Always-On is suspended.",
                                          remedy: "Improve ventilation; do not run with the lid closed in an enclosed space."))
        case .serious:
            checks.append(DiagnosticCheck(id: "power.thermal", category: .power, title: "Thermal state", outcome: .warning,
                                          detail: "Thermal state is serious; intensive services are stopped.",
                                          remedy: "Improve ventilation or reduce load."))
        default:
            checks.append(DiagnosticCheck(id: "power.thermal", category: .power, title: "Thermal state", outcome: .pass,
                                          detail: "Thermal state is \(s.system.thermal.rawValue)."))
        }

        if let pm = context.pmsetSettings {
            if pm["autorestart"] == "0" {
                checks.append(DiagnosticCheck(id: "power.autorestart", category: .power, title: "Restart after power failure", outcome: .info,
                                              detail: "The Mac will not power on by itself after a power outage.",
                                              remedy: "For 24/7 use run: sudo pmset -a autorestart 1  (or enable “Start up automatically after a power failure” in Energy settings)."))
            }
            if pm["womp"] == "0" {
                checks.append(DiagnosticCheck(id: "power.womp", category: .power, title: "Wake for network access", outcome: .info,
                                              detail: "Wake for network access is off. Note that even when on, a sleeping Mac cannot be woken through Tailscale — only by LAN devices / a Bonjour Sleep Proxy."))
            }
        }
        return checks
    }

    static func lidCapability(_ s: StatusSnapshot) -> DiagnosticCheck {
        let p = s.power
        let title = "Can the Mac remain awake with the lid closed?"
        if p.lid == .notPresent {
            return DiagnosticCheck(id: "power.lidCapable", category: .power, title: title, outcome: .pass, detail: "Not applicable: this Mac has no lid.")
        }
        if p.systemSleepDisabled == true {
            var detail = "Yes. System sleep is disabled (pmset SleepDisabled = 1), so closing the lid does not sleep the Mac."
            if p.source == .battery {
                detail += " On battery this generates heat inside a closed laptop; the helper will revert it at the battery floor, at serious/critical thermal state, or if the agent stops renewing its lease."
            }
            return DiagnosticCheck(id: "power.lidCapable", category: .power, title: title, outcome: p.source == .battery ? .warning : .pass, detail: detail)
        }
        if p.clamshellCausesSleep == false {
            return DiagnosticCheck(id: "power.lidCapable", category: .power, title: title, outcome: .pass,
                                   detail: "Yes. macOS reports that closing the lid will not cause sleep right now (closed-display mode conditions are met).")
        }
        if s.system.externalDisplayConnected == true && p.source != .battery {
            return DiagnosticCheck(id: "power.lidCapable", category: .power, title: title, outcome: .pass,
                                   detail: "Likely yes. On AC with an external display, macOS supports closed-display (clamshell) mode. An external keyboard or mouse may also be required on some models.")
        }
        var remedy = "Options: (1) connect AC power and an external display to use Apple’s closed-display mode; or (2) install the privileged helper and enable Lid-closed operation in Settings"
        remedy += p.source == .battery ? " and allow it on battery (heat risk)." : "."
        let reason = p.policy.reasons.first { $0.contains("Lid-closed") || $0.contains("lid-closed") }
        return DiagnosticCheck(id: "power.lidCapable", category: .power, title: title, outcome: .warning,
                               detail: "No. Closing the lid will put the Mac to sleep, and remote access will be unavailable until it wakes. Power assertions cannot prevent lid-close sleep." + (reason.map { " \($0)" } ?? ""),
                               remedy: remedy)
    }

    // MARK: Network

    static func networkChecks(_ s: StatusSnapshot) -> [DiagnosticCheck] {
        let n = s.network
        var checks: [DiagnosticCheck] = []
        if n.pathSatisfied {
            let ifaces = n.interfaces.isEmpty ? "" : " via \(n.interfaces.joined(separator: ", "))"
            let ips = n.localIPv4.isEmpty ? "" : " Local IP: \(n.localIPv4.joined(separator: ", "))."
            checks.append(DiagnosticCheck(id: "network.path", category: .network, title: "Network connection", outcome: .pass,
                                          detail: "Connected\(ifaces).\(ips)"))
        } else {
            checks.append(DiagnosticCheck(id: "network.path", category: .network, title: "Network connection", outcome: .fail,
                                          detail: "No usable network path. Wi-Fi may be disconnected or the cable unplugged; remote access is unavailable until it returns.",
                                          remedy: "Check Wi-Fi / Ethernet. The agent re-checks automatically when the network changes."))
        }
        if let gw = n.gateway {
            checks.append(DiagnosticCheck(id: "network.gateway", category: .network, title: "Gateway", outcome: .pass, detail: "Default gateway \(gw)."))
        } else if n.pathSatisfied {
            checks.append(DiagnosticCheck(id: "network.gateway", category: .network, title: "Gateway", outcome: .warning,
                                          detail: "No default gateway found; traffic may not leave the local network."))
        }
        switch n.dnsWorking {
        case true?:
            checks.append(DiagnosticCheck(id: "network.dns", category: .network, title: "DNS resolution", outcome: .pass, detail: "DNS lookups succeed."))
        case false?:
            checks.append(DiagnosticCheck(id: "network.dns", category: .network, title: "DNS resolution", outcome: .fail,
                                          detail: "DNS lookups fail. \(n.detail ?? "") Tailscale may fail to reach its coordination server.",
                                          remedy: "Check the DNS servers in System Settings → Network, or wait for a temporary outage to pass (the agent retries with backoff)."))
        case nil:
            checks.append(DiagnosticCheck(id: "network.dns", category: .network, title: "DNS resolution", outcome: .info, detail: "Not checked yet."))
        }
        switch n.internetReachable {
        case true?:
            checks.append(DiagnosticCheck(id: "network.internet", category: .network, title: "Internet connectivity", outcome: .pass, detail: "The internet is reachable."))
        case false?:
            checks.append(DiagnosticCheck(id: "network.internet", category: .network, title: "Internet connectivity", outcome: .fail,
                                          detail: "The internet is not reachable. Peers outside this LAN cannot connect over Tailscale until it returns."))
        case nil:
            checks.append(DiagnosticCheck(id: "network.internet", category: .network, title: "Internet connectivity", outcome: .info, detail: "Not checked yet."))
        }
        return checks
    }

    // MARK: Tailscale

    static func tailscaleChecks(_ s: StatusSnapshot) -> [DiagnosticCheck] {
        let t = s.tailscale
        guard t.installed else {
            return [DiagnosticCheck(id: "tailscale.installed", category: .tailscale, title: "Tailscale installed", outcome: .fail,
                                    detail: "Tailscale is not installed. Remote access is only possible through Tailscale, so the Mac is not reachable remotely.",
                                    remedy: "Install Tailscale from https://tailscale.com/download/mac (Standalone recommended, or the App Store version; use the open-source tailscaled for access before login), then sign in. This app never installs it for you.")]
        }
        var checks: [DiagnosticCheck] = []
        checks.append(DiagnosticCheck(id: "tailscale.installed", category: .tailscale, title: "Tailscale installed", outcome: .pass,
                                      detail: "Found \(t.variant.rawValue) variant at \(t.cliPath ?? "?")\(t.version.map { ", version \($0)" } ?? "")."))
        if t.connected {
            var detail = "Connected as \(t.dnsName ?? t.hostName ?? "?") (\(t.ipv4 ?? "?"))"
            if let tailnet = t.tailnetName { detail += " on tailnet \(tailnet)" }
            detail += ". \(t.onlinePeerCount) of \(t.peerCount) peers online."
            checks.append(DiagnosticCheck(id: "tailscale.connected", category: .tailscale, title: "Tailscale connectivity", outcome: .pass, detail: detail))
        } else {
            var detail = "Remote access unavailable because Tailscale is not connected. " + (t.lastError ?? TailscaleStatusParser.explain(backendState: t.backendState))
            if let action = t.lastRecoveryAction { detail += " Last recovery action: \(action)." }
            let remedy: String
            switch t.backendState {
            case "NeedsLogin": remedy = "Open the Tailscale app (or run `tailscale up`) and sign in."
            case "NeedsMachineAuth": remedy = "Approve this machine in the Tailscale admin console."
            case "Stopped": remedy = "Turn Tailscale on in its menu bar app, or enable auto-reconnect in Settings."
            default: remedy = "Open the Tailscale app; if it is running, check its status. The agent retries with backoff."
            }
            checks.append(DiagnosticCheck(id: "tailscale.connected", category: .tailscale, title: "Tailscale connectivity", outcome: .fail, detail: detail, remedy: remedy))
        }
        for (index, message) in t.health.enumerated() {
            checks.append(DiagnosticCheck(id: "tailscale.health.\(index)", category: .tailscale, title: "Tailscale health warning", outcome: .warning, detail: message))
        }
        if t.variant == .appStore || t.variant == .standalone {
            checks.append(DiagnosticCheck(id: "tailscale.variant", category: .tailscale, title: "Availability after reboot", outcome: .info,
                                          detail: "The \(t.variant == .appStore ? "App Store" : "Standalone") variant connects after a user logs in. After a reboot (especially with FileVault) the Mac is not reachable until someone logs in at the machine.",
                                          remedy: "For headless 24/7 use consider the open-source tailscaled (LaunchDaemon), which connects before login."))
        }
        return checks
    }

    // MARK: Remote access

    static func remoteAccessChecks(_ s: StatusSnapshot, context: DiagnosticsContext) -> [DiagnosticCheck] {
        let r = s.remoteAccess
        guard s.tailscale.connected else {
            return [DiagnosticCheck(id: "remote.tailscale", category: .remoteAccess, title: "Tailscale reachable", outcome: .fail,
                                    detail: "Remote access is unavailable because Tailscale is not connected; SSH, Screen Sharing and the web dashboard cannot be reached from outside.")]
        }
        var checks = [DiagnosticCheck(id: "remote.tailscale", category: .remoteAccess, title: "Tailscale reachable", outcome: .pass,
                                      detail: "Reach this Mac at \(r.tailscaleHost ?? s.tailscale.dnsName ?? "?") or \(r.tailscaleIP ?? s.tailscale.ipv4 ?? "?").")]
        checks.append(endpointCheck(id: "remote.ssh", title: "SSH reachable", endpoint: r.ssh,
                                    offRemedy: "Enable Remote Login in \(sharingSettingsHint), then connect with: ssh \(NSUserName())@\(r.tailscaleHost ?? "<tailscale-name>")"))
        checks.append(endpointCheck(id: "remote.screenSharing", title: "Remote Desktop reachable", endpoint: r.screenSharing,
                                    offRemedy: "Enable Screen Sharing in \(sharingSettingsHint), then connect with vnc://\(r.tailscaleHost ?? "<tailscale-name>")"))
        if context.webDashboardEnabled {
            checks.append(endpointCheck(id: "remote.web", title: "Web dashboard reachable", endpoint: r.webDashboard,
                                        offRemedy: "Check the agent log; the dashboard binds only to the Tailscale IP and restarts when Tailscale reconnects."))
        }
        return checks
    }

    static func endpointCheck(id: String, title: String, endpoint: EndpointStatus, offRemedy: String) -> DiagnosticCheck {
        switch endpoint.available {
        case true?:
            return DiagnosticCheck(id: id, category: .remoteAccess, title: title, outcome: .pass, detail: endpoint.detail)
        case false?:
            return DiagnosticCheck(id: id, category: .remoteAccess, title: title, outcome: .warning, detail: endpoint.detail, remedy: offRemedy)
        case nil:
            return DiagnosticCheck(id: id, category: .remoteAccess, title: title, outcome: .info, detail: endpoint.detail)
        }
    }

    // MARK: Services

    static func serviceChecks(_ s: StatusSnapshot) -> [DiagnosticCheck] {
        guard !s.services.isEmpty else {
            return [DiagnosticCheck(id: "services.none", category: .services, title: "Configured services", outcome: .info,
                                    detail: "No background applications are configured.")]
        }
        return s.services.map { svc in
            let outcome: DiagnosticOutcome
            var detail: String
            switch svc.state {
            case .running:
                outcome = svc.healthy == false ? .warning : .pass
                detail = "Running\(svc.pid.map { " (pid \($0))" } ?? "")."
                if svc.healthy == false { detail += " The health-check port is not accepting connections." }
            case .starting:
                outcome = .info
                detail = "Starting."
            case .stopped:
                outcome = .info
                detail = "Stopped."
            case .restarting:
                outcome = .warning
                detail = "Crashed (\(svc.lastExitDescription ?? "unknown")); restart #\(svc.restartCount) scheduled\(svc.nextRestartAt.map { " at \(Formatting.time($0))" } ?? "")."
            case .crashed:
                outcome = .fail
                detail = "Crashed (\(svc.lastExitDescription ?? "unknown")) and auto-restart is off for this kind of exit."
            case .failed:
                outcome = .fail
                detail = svc.note ?? "Gave up restarting after repeated crashes."
            case .suspended:
                outcome = .info
                detail = "Suspended by power policy: \(svc.note ?? "battery / thermal limit")."
            case .waitingForNetwork:
                outcome = .warning
                detail = "Waiting for the network before launching."
            }
            return DiagnosticCheck(id: "services.\(svc.id)", category: .services, title: svc.name, outcome: outcome, detail: detail,
                                   remedy: (svc.state == .failed || svc.state == .crashed) ? "See its log in ~/Library/Logs/MacAlwaysOn/services, fix the cause, then press Start." : nil)
        }
    }

    // MARK: Security

    static func securityChecks(_ s: StatusSnapshot, context: DiagnosticsContext) -> [DiagnosticCheck] {
        var checks: [DiagnosticCheck] = []
        checks.append(DiagnosticCheck(id: "security.portForwarding", category: .security, title: "Public exposure", outcome: .info,
                                      detail: "MacAlwaysOn never configures router port forwarding, UPnP or NAT-PMP, and never listens on 0.0.0.0. It cannot inspect your router.",
                                      remedy: "Confirm your router has no port-forwarding rules pointing at this Mac and that UPnP is disabled."))
        if let listeners = context.listeners {
            let exposed = listeners.filter { $0.exposure == .wildcard || $0.exposure == .lan }
            let restricted = Set(s.remoteAccess.firewallRestricted == true ? context.restrictedTCPPorts : [])
            let unrestricted = exposed.filter { !restricted.contains($0.port) }
            let ports = Array(Set(unrestricted.map(\.port))).sorted()
            if ports.isEmpty {
                checks.append(DiagnosticCheck(id: "security.listeners", category: .security, title: "Listening ports", outcome: .pass,
                                              detail: exposed.isEmpty ? "No TCP service listens beyond loopback/Tailscale." : "Remote-access ports are restricted to the tailnet by the pf anchor."))
            } else {
                let list = ports.map(String.init).joined(separator: ", ")
                checks.append(DiagnosticCheck(id: "security.listeners", category: .security, title: "Listening ports", outcome: .warning,
                                              detail: "TCP ports \(list) listen on all interfaces. They are not reachable from the internet unless a router forwards them, but devices on the same LAN can reach them.",
                                              remedy: "Enable “Restrict remote-access ports to Tailscale” (needs the helper) for the ports you use, or turn off sharing services you do not need."))
            }
        }
        if let restricted = s.remoteAccess.firewallRestricted {
            checks.append(DiagnosticCheck(id: "security.pf", category: .security, title: "Tailnet-only firewall", outcome: restricted ? .pass : .info,
                                          detail: restricted ? "pf anchor active: remote-access ports accept connections only from Tailscale and loopback." : "The tailnet-only pf anchor is not active."))
        }
        if s.remoteAccess.webDashboard.available == true, let addr = s.remoteAccess.webDashboard.address {
            let ok = addr.split(separator: ":").first.flatMap { IPv4Address(String($0)) }?.isTailscale ?? false
            checks.append(DiagnosticCheck(id: "security.webBinding", category: .security, title: "Web dashboard binding", outcome: ok ? .pass : .fail,
                                          detail: ok ? "The web dashboard listens only on the Tailscale address \(addr)." : "The web dashboard is bound to \(addr), which is not a Tailscale address."))
        }
        return checks
    }
}

public enum HealthSummarizer {
    public static func summarize(_ s: StatusSnapshot) -> OverallHealth {
        var level = HealthLevel.healthy
        var summary: [String] = []
        func raise(_ l: HealthLevel, _ message: String) {
            level = max(level, l)
            summary.append(message)
        }
        if !s.network.pathSatisfied { raise(.unhealthy, "No network connection") }
        if !s.tailscale.installed { raise(.unhealthy, "Tailscale not installed") }
        else if !s.tailscale.connected { raise(.unhealthy, "Tailscale disconnected") }
        if s.power.policy.preventIdleSleep && !s.power.assertions.idleSleepPrevented { raise(.degraded, "Sleep assertion not held") }
        if s.power.policy.mode == .relaxed { raise(.degraded, "Always-On relaxed (battery/thermal)") }
        if s.system.thermal >= .serious { raise(.degraded, "Thermal state \(s.system.thermal.rawValue)") }
        let broken = s.services.filter { $0.state == .failed || $0.state == .crashed }
        if !broken.isEmpty { raise(.degraded, "\(broken.count) service(s) crashed") }
        if s.services.contains(where: { $0.healthy == false }) { raise(.degraded, "Service health check failing") }
        if summary.isEmpty { summary.append("All systems normal") }
        return OverallHealth(level: level, summary: summary)
    }
}

public enum Formatting {
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h \((s % 3600) / 60) min" }
        return "\(s / 86400) d \((s % 86400) / 3600) h"
    }

    public static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: date)
    }

    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return i == 0 ? "\(value) B" : String(format: "%.1f %@", v, units[i])
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value)
    }
}
