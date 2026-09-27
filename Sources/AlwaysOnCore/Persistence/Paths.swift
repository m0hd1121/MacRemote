import Foundation

public enum Identifiers {
    public static let appBundleID = "com.macalwayson.app"
    public static let agentLabel = "com.macalwayson.agent"
    public static let helperLabel = "com.macalwayson.helper"
    public static let version = "1.0.0"
}

/// Per-user locations (agent + GUI).
public struct UserPaths: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var supportDirectory: URL { home.appendingPathComponent("Library/Application Support/MacAlwaysOn", isDirectory: true) }
    public var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public var runDirectory: URL { supportDirectory.appendingPathComponent("run", isDirectory: true) }
    public var agentSocket: URL { runDirectory.appendingPathComponent("agent.sock") }
    public var pidRegistry: URL { runDirectory.appendingPathComponent("children.json") }
    public var logsDirectory: URL { home.appendingPathComponent("Library/Logs/MacAlwaysOn", isDirectory: true) }
    public var agentLog: URL { logsDirectory.appendingPathComponent("agent.log") }
    public var serviceLogsDirectory: URL { logsDirectory.appendingPathComponent("services", isDirectory: true) }
    public var launchAgentPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(Identifiers.agentLabel).plist") }

    public func serviceLog(for spec: ServiceSpec) -> URL {
        serviceLogsDirectory.appendingPathComponent("\(spec.logFileStem).log")
    }
}

/// System-wide locations owned by root (privileged helper).
public enum SystemPaths {
    public static let helperSocket = "/var/run/com.macalwayson.helper.sock"
    public static let helperSupportDirectory = "/Library/Application Support/MacAlwaysOn"
    public static let helperState = helperSupportDirectory + "/helper-state.json"
    /// One numeric UID per line. Root-owned; written by the installer.
    public static let helperAuthorizedUIDs = helperSupportDirectory + "/helper-authorized-uids"
    public static let helperLogDirectory = "/Library/Logs/MacAlwaysOn"
    public static let helperLog = helperLogDirectory + "/helper.log"
    public static let helperBinary = "/Library/PrivilegedHelperTools/\(Identifiers.helperLabel)"
    public static let helperPlist = "/Library/LaunchDaemons/\(Identifiers.helperLabel).plist"
    public static let pmset = "/usr/bin/pmset"
    public static let pfctl = "/sbin/pfctl"
    public static let netstat = "/usr/sbin/netstat"
    public static let route = "/sbin/route"
    public static let open = "/usr/bin/open"
    public static let launchctl = "/bin/launchctl"
}
