import Foundation

public enum PowerSourceKind: String, Codable, Sendable {
    case ac, battery, ups, unknown
}

public enum LidState: String, Codable, Sendable {
    case open, closed
    /// Desktop Macs have no lid; the registry key is absent.
    case notPresent
    case unknown
}

public enum ServiceState: String, Codable, Sendable {
    case stopped, starting, running, crashed, restarting
    /// Gave up after too many restarts inside the window; needs a manual start.
    case failed
    /// Stopped by the power policy (battery / thermal); restarts automatically when allowed.
    case suspended
    /// Waiting for the network before first launch.
    case waitingForNetwork
}

public enum HealthLevel: String, Codable, Sendable, Comparable {
    case healthy, degraded, unhealthy

    private var rank: Int {
        switch self {
        case .healthy: return 0
        case .degraded: return 1
        case .unhealthy: return 2
        }
    }

    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rank < rhs.rank }
}

public struct AgentInfo: Codable, Equatable, Sendable {
    public var version: String
    public var pid: Int32
    public var startedAt: Date
    public var cpuPercent: Double?
    public var residentBytes: UInt64?

    public init(version: String, pid: Int32, startedAt: Date, cpuPercent: Double? = nil, residentBytes: UInt64? = nil) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }
}

public struct SystemStatus: Codable, Equatable, Sendable {
    public var model = ""
    public var osVersion = ""
    public var bootTime: Date?
    public var cpuPercent: Double?
    public var memoryUsedBytes: UInt64?
    public var memoryTotalBytes: UInt64?
    /// "normal", "warning" or "critical".
    public var memoryPressure: String?
    public var diskFreeBytes: UInt64?
    public var diskTotalBytes: UInt64?
    public var thermal: ThermalLevel = .nominal
    public var externalDisplayConnected: Bool?

    public init() {}
}

public struct AssertionStatus: Codable, Equatable, Sendable {
    public var idleSleepPrevented = false
    public var systemSleepPrevented = false
    public var displaySleepPrevented = false

    public init() {}
}

public struct PowerStatus: Codable, Equatable, Sendable {
    public var source: PowerSourceKind = .unknown
    public var hasBattery = false
    public var batteryPercent: Int?
    public var isCharging: Bool?
    public var isCharged: Bool?
    public var timeRemainingMinutes: Int?
    public var batteryHealth: String?
    public var cycleCount: Int?
    public var lid: LidState = .unknown
    /// `AppleClamshellCausesSleep`: false means closing the lid will not sleep the Mac right now.
    public var clamshellCausesSleep: Bool?
    public var lastSleepAt: Date?
    public var lastWakeAt: Date?
    public var assertions = AssertionStatus()
    /// `SleepDisabled` as reported by `pmset -g` (nil when unknown).
    public var systemSleepDisabled: Bool?
    public var policy = PolicyDecision.inactive

    public init() {}
}

public struct NetworkStatus: Codable, Equatable, Sendable {
    public var pathSatisfied = false
    /// e.g. ["wifi:en0", "ethernet:en5"].
    public var interfaces: [String] = []
    public var primaryInterfaceType: String?
    public var localIPv4: [String] = []
    public var gateway: String?
    public var dnsWorking: Bool?
    public var internetReachable: Bool?
    public var lastCheckedAt: Date?
    public var lastChangeAt: Date?
    public var detail: String?

    public init() {}
}

public enum TailscaleVariant: String, Codable, Sendable {
    case appStore, standalone, openSource, unknown, notInstalled
}

public struct TailscaleStatus: Codable, Equatable, Sendable {
    public var installed = false
    public var variant: TailscaleVariant = .notInstalled
    public var cliPath: String?
    public var version: String?
    /// Raw `BackendState`: NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running.
    public var backendState: String?
    public var connected = false
    public var ipv4: String?
    public var ipv6: String?
    public var hostName: String?
    public var dnsName: String?
    public var tailnetName: String?
    public var magicDNSSuffix: String?
    public var selfOnline: Bool?
    public var peerCount = 0
    public var onlinePeerCount = 0
    public var health: [String] = []
    public var lastConnectedAt: Date?
    public var lastCheckedAt: Date?
    public var lastError: String?
    public var lastRecoveryAction: String?

    public init() {}
}

public struct ServiceStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: ServiceKind
    public var priority: ServicePriority
    public var state: ServiceState
    public var pid: Int32?
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?
    public var lastLaunchAt: Date?
    public var lastExitAt: Date?
    public var lastCrashAt: Date?
    public var lastExitDescription: String?
    public var restartCount: Int
    public var nextRestartAt: Date?
    public var healthy: Bool?
    public var note: String?

    public init(id: String, name: String, kind: ServiceKind, priority: ServicePriority, state: ServiceState,
                pid: Int32? = nil, cpuPercent: Double? = nil, memoryBytes: UInt64? = nil,
                lastLaunchAt: Date? = nil, lastExitAt: Date? = nil, lastCrashAt: Date? = nil,
                lastExitDescription: String? = nil, restartCount: Int = 0, nextRestartAt: Date? = nil,
                healthy: Bool? = nil, note: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.priority = priority
        self.state = state
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.lastLaunchAt = lastLaunchAt
        self.lastExitAt = lastExitAt
        self.lastCrashAt = lastCrashAt
        self.lastExitDescription = lastExitDescription
        self.restartCount = restartCount
        self.nextRestartAt = nextRestartAt
        self.healthy = healthy
        self.note = note
    }
}

public struct EndpointStatus: Codable, Equatable, Sendable {
    public var available: Bool?
    public var address: String?
    public var detail: String

    public init(available: Bool?, address: String? = nil, detail: String) {
        self.available = available
        self.address = address
        self.detail = detail
    }

    public static let unknown = EndpointStatus(available: nil, detail: "Not checked yet")
}

public struct RemoteAccessStatus: Codable, Equatable, Sendable {
    public var tailscaleHost: String?
    public var tailscaleIP: String?
    public var ssh = EndpointStatus.unknown
    public var screenSharing = EndpointStatus.unknown
    public var webDashboard = EndpointStatus.unknown
    public var firewallRestricted: Bool?
    public var lastCheckedAt: Date?

    public init() {}
}

public struct HelperStatus: Codable, Equatable, Sendable {
    public var installed = false
    public var reachable = false
    public var state: HelperState?
    public var error: String?

    public init() {}
}

public struct OverallHealth: Codable, Equatable, Sendable {
    public var level: HealthLevel = .healthy
    public var summary: [String] = []

    public init(level: HealthLevel = .healthy, summary: [String] = []) {
        self.level = level
        self.summary = summary
    }
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    /// How often a live agent refreshes. Consumers treat a snapshot older than twice this as stale.
    public var refreshIntervalSeconds: Double
    public var agent: AgentInfo
    public var system = SystemStatus()
    public var power = PowerStatus()
    public var network = NetworkStatus()
    public var tailscale = TailscaleStatus()
    public var services: [ServiceStatus] = []
    public var remoteAccess = RemoteAccessStatus()
    public var helper = HelperStatus()
    public var overall = OverallHealth()

    public init(generatedAt: Date, refreshIntervalSeconds: Double, agent: AgentInfo) {
        self.generatedAt = generatedAt
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.agent = agent
    }

    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(generatedAt) > max(refreshIntervalSeconds * 2, 10)
    }
}
