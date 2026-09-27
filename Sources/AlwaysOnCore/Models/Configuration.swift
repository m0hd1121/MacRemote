import Foundation

/// How Always-On behaves while running on battery.
public enum BatteryMode: String, Codable, CaseIterable, Sendable {
    /// Full Always-On on battery. Below the threshold it steps down to Battery Saver.
    case alwaysOn
    /// Keep networking and essential services only; no lid-closed override.
    case batterySaver
    /// Full Always-On above the threshold; below it, relax completely (normal sleep).
    case disableBelowThreshold
    /// Full Always-On until the threshold is reached once; then stay off until AC returns.
    case disableAtThreshold

    public var displayName: String {
        switch self {
        case .alwaysOn: return "Always On"
        case .batterySaver: return "Battery Saver"
        case .disableBelowThreshold: return "Disable below threshold"
        case .disableAtThreshold: return "Disable when threshold reached"
        }
    }
}

/// Mirrors `ProcessInfo.ThermalState` in a platform-neutral, ordered form.
public enum ThermalLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case nominal, fair, serious, critical

    private var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }
}

public enum LogLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case debug, info, warning, error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

public struct PowerSettings: Codable, Equatable, Sendable {
    /// Master switch for Always-On mode.
    public var alwaysOnEnabled = true
    /// Apply Always-On while on AC power.
    public var acModeEnabled = true
    /// Apply Always-On while on battery (subject to `batteryMode`).
    public var batteryModeEnabled = true
    public var batteryMode: BatteryMode = .disableBelowThreshold
    /// Threshold used by the battery modes, in percent.
    public var batteryThresholdPercent = 30
    /// Battery must climb this many points above the threshold before Always-On re-arms.
    public var hysteresisPercent = 5
    /// Stop non-essential services when the battery policy relaxes.
    public var stopNonEssentialOnLowBattery = true
    /// Keep the display awake too (off by default: display sleep costs nothing for remote access).
    public var preventDisplaySleep = false

    /// Keep running with the lid closed and no external display. Requires the privileged helper
    /// (`pmset disablesleep`). Off by default.
    public var lidClosedOperation = false
    /// Also allow lid-closed operation on battery. Off by default because of heat risk.
    public var lidClosedOnBattery = false
    /// Hard floor enforced by the root helper itself, independent of the agent.
    public var helperBatteryFloorPercent = 25
    /// At or above this thermal level the lid-closed override is withdrawn on battery and
    /// intensive services are stopped.
    public var maxThermalLevel: ThermalLevel = .serious
    /// On battery, stop intensive services when system CPU stays above this for 3 samples.
    public var maxCPUPercentOnBattery = 85

    public init() {}
}

public struct TailscaleSettings: Codable, Equatable, Sendable {
    /// Relaunch the Tailscale app if it quit, and run `tailscale up` if the backend is Stopped.
    public var autoReconnect = true
    /// Optional absolute path to the `tailscale` CLI; empty means auto-detect.
    public var cliPathOverride = ""
    /// Poll interval while healthy. Unhealthy states use exponential backoff instead.
    public var statusIntervalSeconds = 60

    public init() {}
}

public struct RemoteAccessSettings: Codable, Equatable, Sendable {
    public var webDashboardEnabled = true
    public var webDashboardPort = 8686
    /// If non-empty, only these Tailscale login names may view the web dashboard.
    public var webDashboardAllowedLogins: [String] = []
    public var probeSSH = true
    public var probeScreenSharing = true
    /// Ask the privileged helper to restrict the ports below to the tailnet with a pf anchor.
    public var restrictPortsToTailnet = false
    public var restrictedTCPPorts: [Int] = [22, 3283, 5900]
    public var restrictedUDPPorts: [Int] = [3283, 5900]

    public init() {}
}

public struct DiagnosticsSettings: Codable, Equatable, Sendable {
    public var intervalSeconds = 300
    public var dnsProbeHost = "controlplane.tailscale.com"
    public var internetProbeHost = "controlplane.tailscale.com"
    public var internetProbePort = 443

    public init() {}
}

public struct LoggingSettings: Codable, Equatable, Sendable {
    public var level: LogLevel = .info
    public var maxFileBytes = 2 * 1024 * 1024
    public var maxFiles = 5

    public init() {}
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = AppConfiguration.currentVersion
    public var power = PowerSettings()
    public var tailscale = TailscaleSettings()
    public var remoteAccess = RemoteAccessSettings()
    public var diagnostics = DiagnosticsSettings()
    public var logging = LoggingSettings()
    public var services: [ServiceSpec] = []

    public init() {}

    /// Clamp values edited by hand into safe ranges. Returns human-readable corrections.
    @discardableResult
    public mutating func sanitize() -> [String] {
        var notes: [String] = []
        func clamp(_ value: inout Int, _ range: ClosedRange<Int>, _ name: String) {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            if clamped != value {
                notes.append("\(name) \(value) out of range; using \(clamped)")
                value = clamped
            }
        }
        clamp(&power.batteryThresholdPercent, 5...95, "batteryThresholdPercent")
        clamp(&power.hysteresisPercent, 0...20, "hysteresisPercent")
        clamp(&power.helperBatteryFloorPercent, 10...90, "helperBatteryFloorPercent")
        clamp(&power.maxCPUPercentOnBattery, 10...100, "maxCPUPercentOnBattery")
        clamp(&tailscale.statusIntervalSeconds, 15...3600, "tailscale.statusIntervalSeconds")
        clamp(&remoteAccess.webDashboardPort, 1024...65535, "webDashboardPort")
        clamp(&diagnostics.intervalSeconds, 30...86400, "diagnostics.intervalSeconds")
        clamp(&diagnostics.internetProbePort, 1...65535, "internetProbePort")
        clamp(&logging.maxFileBytes, 64 * 1024...64 * 1024 * 1024, "logging.maxFileBytes")
        clamp(&logging.maxFiles, 1...20, "logging.maxFiles")

        let validPort: (Int) -> Bool = { (1...65535).contains($0) }
        let tcp = Array(Set(remoteAccess.restrictedTCPPorts.filter(validPort))).sorted()
        let udp = Array(Set(remoteAccess.restrictedUDPPorts.filter(validPort))).sorted()
        if tcp.count > HelperLimits.maxPorts || udp.count > HelperLimits.maxPorts {
            notes.append("at most \(HelperLimits.maxPorts) restricted ports per protocol; extra ports ignored")
        }
        remoteAccess.restrictedTCPPorts = Array(tcp.prefix(HelperLimits.maxPorts))
        remoteAccess.restrictedUDPPorts = Array(udp.prefix(HelperLimits.maxPorts))

        var seen = Set<String>()
        services = services.filter { spec in
            guard !seen.contains(spec.id) else {
                notes.append("duplicate service id \(spec.id) dropped")
                return false
            }
            seen.insert(spec.id)
            return true
        }
        for index in services.indices {
            notes += services[index].backoff.sanitize(prefix: services[index].name)
        }
        return notes
    }
}

// MARK: - Tolerant decoding
//
// Config files are edited by the GUI and occasionally by hand. Missing keys fall back to
// defaults instead of failing the whole file, so upgrades that add settings keep working.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

extension PowerSettings {
    private enum CodingKeys: String, CodingKey {
        case alwaysOnEnabled, acModeEnabled, batteryModeEnabled, batteryMode, batteryThresholdPercent
        case hysteresisPercent, stopNonEssentialOnLowBattery, preventDisplaySleep, lidClosedOperation
        case lidClosedOnBattery, helperBatteryFloorPercent, maxThermalLevel, maxCPUPercentOnBattery
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PowerSettings()
        alwaysOnEnabled = try c.value(.alwaysOnEnabled, default: d.alwaysOnEnabled)
        acModeEnabled = try c.value(.acModeEnabled, default: d.acModeEnabled)
        batteryModeEnabled = try c.value(.batteryModeEnabled, default: d.batteryModeEnabled)
        batteryMode = try c.value(.batteryMode, default: d.batteryMode)
        batteryThresholdPercent = try c.value(.batteryThresholdPercent, default: d.batteryThresholdPercent)
        hysteresisPercent = try c.value(.hysteresisPercent, default: d.hysteresisPercent)
        stopNonEssentialOnLowBattery = try c.value(.stopNonEssentialOnLowBattery, default: d.stopNonEssentialOnLowBattery)
        preventDisplaySleep = try c.value(.preventDisplaySleep, default: d.preventDisplaySleep)
        lidClosedOperation = try c.value(.lidClosedOperation, default: d.lidClosedOperation)
        lidClosedOnBattery = try c.value(.lidClosedOnBattery, default: d.lidClosedOnBattery)
        helperBatteryFloorPercent = try c.value(.helperBatteryFloorPercent, default: d.helperBatteryFloorPercent)
        maxThermalLevel = try c.value(.maxThermalLevel, default: d.maxThermalLevel)
        maxCPUPercentOnBattery = try c.value(.maxCPUPercentOnBattery, default: d.maxCPUPercentOnBattery)
    }
}

extension TailscaleSettings {
    private enum CodingKeys: String, CodingKey { case autoReconnect, cliPathOverride, statusIntervalSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TailscaleSettings()
        autoReconnect = try c.value(.autoReconnect, default: d.autoReconnect)
        cliPathOverride = try c.value(.cliPathOverride, default: d.cliPathOverride)
        statusIntervalSeconds = try c.value(.statusIntervalSeconds, default: d.statusIntervalSeconds)
    }
}

extension RemoteAccessSettings {
    private enum CodingKeys: String, CodingKey {
        case webDashboardEnabled, webDashboardPort, webDashboardAllowedLogins, probeSSH, probeScreenSharing
        case restrictPortsToTailnet, restrictedTCPPorts, restrictedUDPPorts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RemoteAccessSettings()
        webDashboardEnabled = try c.value(.webDashboardEnabled, default: d.webDashboardEnabled)
        webDashboardPort = try c.value(.webDashboardPort, default: d.webDashboardPort)
        webDashboardAllowedLogins = try c.value(.webDashboardAllowedLogins, default: d.webDashboardAllowedLogins)
        probeSSH = try c.value(.probeSSH, default: d.probeSSH)
        probeScreenSharing = try c.value(.probeScreenSharing, default: d.probeScreenSharing)
        restrictPortsToTailnet = try c.value(.restrictPortsToTailnet, default: d.restrictPortsToTailnet)
        restrictedTCPPorts = try c.value(.restrictedTCPPorts, default: d.restrictedTCPPorts)
        restrictedUDPPorts = try c.value(.restrictedUDPPorts, default: d.restrictedUDPPorts)
    }
}

extension DiagnosticsSettings {
    private enum CodingKeys: String, CodingKey { case intervalSeconds, dnsProbeHost, internetProbeHost, internetProbePort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DiagnosticsSettings()
        intervalSeconds = try c.value(.intervalSeconds, default: d.intervalSeconds)
        dnsProbeHost = try c.value(.dnsProbeHost, default: d.dnsProbeHost)
        internetProbeHost = try c.value(.internetProbeHost, default: d.internetProbeHost)
        internetProbePort = try c.value(.internetProbePort, default: d.internetProbePort)
    }
}

extension LoggingSettings {
    private enum CodingKeys: String, CodingKey { case level, maxFileBytes, maxFiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LoggingSettings()
        level = try c.value(.level, default: d.level)
        maxFileBytes = try c.value(.maxFileBytes, default: d.maxFileBytes)
        maxFiles = try c.value(.maxFiles, default: d.maxFiles)
    }
}

extension AppConfiguration {
    private enum CodingKeys: String, CodingKey { case version, power, tailscale, remoteAccess, diagnostics, logging, services }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.value(.version, default: AppConfiguration.currentVersion)
        power = try c.value(.power, default: PowerSettings())
        tailscale = try c.value(.tailscale, default: TailscaleSettings())
        remoteAccess = try c.value(.remoteAccess, default: RemoteAccessSettings())
        diagnostics = try c.value(.diagnostics, default: DiagnosticsSettings())
        logging = try c.value(.logging, default: LoggingSettings())
        services = try c.value(.services, default: [])
    }
}
