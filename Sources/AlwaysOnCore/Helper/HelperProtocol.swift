import Foundation

public enum HelperLimits {
    public static let maxPorts = 16
    public static let batteryFloorRange = 10...90
    public static let leaseRange: ClosedRange<Double> = 120...3600
    public static let defaultLeaseSeconds: Double = 600
}

public enum HelperCommand: String, Codable, Sendable {
    case status
    case setLidClosedOperation
    case setFirewall
}

public struct LidClosedRequest: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var allowOnBattery: Bool
    public var batteryFloorPercent: Int
    public var leaseSeconds: Double

    public init(enabled: Bool, allowOnBattery: Bool, batteryFloorPercent: Int, leaseSeconds: Double = HelperLimits.defaultLeaseSeconds) {
        self.enabled = enabled
        self.allowOnBattery = allowOnBattery
        self.batteryFloorPercent = batteryFloorPercent
        self.leaseSeconds = leaseSeconds
    }
}

public struct FirewallRequest: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var tcpPorts: [Int]
    public var udpPorts: [Int]

    public init(enabled: Bool, tcpPorts: [Int], udpPorts: [Int]) {
        self.enabled = enabled
        self.tcpPorts = tcpPorts
        self.udpPorts = udpPorts
    }
}

public struct HelperRequest: Codable, Equatable, Sendable {
    public var command: HelperCommand
    public var lidClosed: LidClosedRequest?
    public var firewall: FirewallRequest?

    public init(command: HelperCommand, lidClosed: LidClosedRequest? = nil, firewall: FirewallRequest? = nil) {
        self.command = command
        self.lidClosed = lidClosed
        self.firewall = firewall
    }
}

/// Persistent state of the root helper (also returned to clients).
public struct HelperState: Codable, Equatable, Sendable {
    public var lidOverrideRequested = false
    /// True only when *this helper* set `disablesleep 1` and has not reverted it.
    public var lidOverrideApplied = false
    public var allowOnBattery = false
    public var batteryFloorPercent = 25
    public var leaseExpiresAt: Date?
    /// `SleepDisabled` read back from `pmset -g` at the last check.
    public var systemSleepDisabled: Bool?
    public var firewallEnabled = false
    public var firewallTCPPorts: [Int] = []
    public var firewallUDPPorts: [Int] = []
    public var firewallActive = false
    /// Reference token from `pfctl -E`, released with `pfctl -X` on disable.
    public var pfToken: String?
    public var lastRevertReason: String?
    public var lastRevertAt: Date?
    public var lastError: String?

    public init() {}
}

public struct HelperResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var state: HelperState?

    public init(ok: Bool, error: String? = nil, state: HelperState? = nil) {
        self.ok = ok
        self.error = error
        self.state = state
    }
}

public enum HelperValidation {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case missingPayload
        case batteryFloorOutOfRange(Int)
        case leaseOutOfRange(Double)
        case tooManyPorts(Int)
        case invalidPort(Int)

        public var description: String {
            switch self {
            case .missingPayload: return "request payload missing"
            case .batteryFloorOutOfRange(let v): return "battery floor \(v) outside \(HelperLimits.batteryFloorRange)"
            case .leaseOutOfRange(let v): return "lease \(v)s outside \(HelperLimits.leaseRange)"
            case .tooManyPorts(let n): return "\(n) ports requested; maximum is \(HelperLimits.maxPorts)"
            case .invalidPort(let p): return "invalid port \(p)"
            }
        }
    }

    public static func validate(_ request: LidClosedRequest) throws {
        guard HelperLimits.batteryFloorRange.contains(request.batteryFloorPercent) else {
            throw Failure.batteryFloorOutOfRange(request.batteryFloorPercent)
        }
        guard HelperLimits.leaseRange.contains(request.leaseSeconds), request.leaseSeconds.isFinite else {
            throw Failure.leaseOutOfRange(request.leaseSeconds)
        }
    }

    public static func validate(_ request: FirewallRequest) throws {
        for list in [request.tcpPorts, request.udpPorts] {
            guard list.count <= HelperLimits.maxPorts else { throw Failure.tooManyPorts(list.count) }
            for port in list where !(1...65535).contains(port) { throw Failure.invalidPort(port) }
        }
    }
}

/// Power facts the helper's safety loop needs.
public struct HelperPowerFacts: Equatable, Sendable {
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var thermal: ThermalLevel

    public init(onBattery: Bool, batteryPercent: Int?, thermal: ThermalLevel) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }
}

public enum HelperSafety {
    /// Returns why an applied lid-closed override must be reverted now, or nil if it may stay.
    /// This runs inside the root helper independently of the agent.
    public static func revertReason(state: HelperState, facts: HelperPowerFacts, now: Date) -> String? {
        guard state.lidOverrideApplied else { return nil }
        if !state.lidOverrideRequested { return "override no longer requested" }
        guard let expiry = state.leaseExpiresAt else { return "no lease" }
        if now >= expiry { return "lease expired (agent stopped renewing)" }
        if facts.thermal >= .critical { return "thermal state critical" }
        if facts.onBattery {
            if !state.allowOnBattery { return "running on battery and battery operation not allowed" }
            guard let pct = facts.batteryPercent else { return "battery level unknown on battery" }
            if pct <= state.batteryFloorPercent { return "battery \(pct)% at or below floor \(state.batteryFloorPercent)%" }
            if facts.thermal >= .serious { return "thermal state serious on battery" }
        }
        return nil
    }

    /// Whether a new override request may be applied right now.
    public static func mayApply(request: LidClosedRequest, facts: HelperPowerFacts) -> String? {
        if facts.thermal >= .critical { return "thermal state critical" }
        if facts.onBattery {
            if !request.allowOnBattery { return "on battery and battery operation not allowed" }
            guard let pct = facts.batteryPercent else { return "battery level unknown" }
            if pct <= request.batteryFloorPercent { return "battery \(pct)% at or below floor \(request.batteryFloorPercent)%" }
            if facts.thermal >= .serious { return "thermal state serious on battery" }
        }
        return nil
    }
}

/// Renders the pf anchor loaded under `com.apple/250.MacAlwaysOn`.
public enum PFRules {
    public static let anchorName = "com.apple/250.MacAlwaysOn"
    public static let tailnetIPv4 = "100.64.0.0/10"
    public static let tailnetIPv6 = "fd7a:115c:a1e0::/48"

    public static func render(tcpPorts: [Int], udpPorts: [Int]) -> String {
        var lines = [
            "# Generated by MacAlwaysOn. Allows the listed ports only from Tailscale and loopback.",
            "# Loaded at runtime with pfctl -a \(anchorName); /etc/pf.conf is not modified.",
        ]
        for (proto, ports) in [("tcp", tcpPorts), ("udp", udpPorts)] {
            let clean = Array(Set(ports.filter { (1...65535).contains($0) })).sorted()
            guard !clean.isEmpty else { continue }
            let list = "{ " + clean.map(String.init).joined(separator: " ") + " }"
            lines.append("pass in quick on lo0 proto \(proto) from any to any port \(list)")
            lines.append("pass in quick inet proto \(proto) from \(tailnetIPv4) to any port \(list)")
            lines.append("pass in quick inet6 proto \(proto) from \(tailnetIPv6) to any port \(list)")
            lines.append("block drop in quick proto \(proto) from any to any port \(list)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
