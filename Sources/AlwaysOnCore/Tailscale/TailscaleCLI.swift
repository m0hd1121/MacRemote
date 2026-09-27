import Foundation

public struct TailscaleInstallation: Equatable, Sendable {
    public var cliPath: String
    public var variant: TailscaleVariant
    /// Bundle identifier of the GUI app (App Store / Standalone variants), used for relaunching.
    public var appBundleID: String?
}

public enum TailscaleCLIError: Error, CustomStringConvertible {
    case notInstalled
    case commandFailed(String)
    case unparsable(String)

    public var description: String {
        switch self {
        case .notInstalled: return "Tailscale is not installed."
        case .commandFailed(let message): return message
        case .unparsable(let message): return "Could not parse tailscale output: \(message)"
        }
    }
}

/// Wraps the official `tailscale` CLI. Never installs or configures Tailscale itself.
public struct TailscaleCLI: Sendable {
    public static let appPath = "/Applications/Tailscale.app"
    public static let appCLIPath = appPath + "/Contents/MacOS/Tailscale"
    public static let candidatePaths = [
        appCLIPath,
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/bin/tailscale",
    ]
    public static let appStoreBundleID = "io.tailscale.ipn.macos"
    public static let standaloneBundleID = "io.tailscale.ipn.macsys"

    public let installation: TailscaleInstallation
    private let runner: CommandRunning

    public init(installation: TailscaleInstallation, runner: CommandRunning = ShellRunner()) {
        self.installation = installation
        self.runner = runner
    }

    public static func locate(override: String = "", fileManager: FileManager = .default) -> TailscaleInstallation? {
        let candidates = (override.isEmpty ? [] : [override]) + candidatePaths
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            if path.hasPrefix(appPath + "/") {
                let bundleID = appBundleIdentifier(fileManager: fileManager)
                let variant: TailscaleVariant
                switch bundleID {
                case appStoreBundleID?: variant = .appStore
                case standaloneBundleID?: variant = .standalone
                default: variant = .unknown
                }
                return TailscaleInstallation(cliPath: path, variant: variant, appBundleID: bundleID)
            }
            return TailscaleInstallation(cliPath: path, variant: .openSource, appBundleID: nil)
        }
        return nil
    }

    private static func appBundleIdentifier(fileManager: FileManager) -> String? {
        let plist = URL(fileURLWithPath: appPath + "/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return dict["CFBundleIdentifier"] as? String
    }

    public func status() throws -> TailscaleParsedStatus {
        let result = try runner.run(installation.cliPath, ["status", "--json"], stdin: nil, timeout: 15)
        // `status --json` prints valid JSON even when the backend is Stopped / NeedsLogin
        // (sometimes with a non-zero exit), so try to parse first.
        if let data = result.stdout.data(using: .utf8), result.stdout.contains("{"),
           let parsed = try? TailscaleStatusParser.parse(data) {
            return parsed
        }
        if result.timedOut { throw TailscaleCLIError.commandFailed("tailscale status timed out") }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw TailscaleCLIError.commandFailed(message.isEmpty ? "tailscale status exited with \(result.status)" : Redactor.redact(message))
    }

    /// Plain `tailscale up` with no flags: re-enables an already configured node without
    /// changing any preferences. Never passes auth keys.
    public func up() throws {
        let result = try runner.run(installation.cliPath, ["up"], stdin: nil, timeout: 30)
        guard result.succeeded else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TailscaleCLIError.commandFailed(Redactor.redact(message.isEmpty ? "tailscale up exited with \(result.status)" : message))
        }
    }

    /// Login name of the tailnet user owning the node at `ip`, or nil.
    public func whoisLogin(ip: String) -> String? {
        guard IPv4Address(ip) != nil || ip.contains(":") else { return nil }
        guard let result = try? runner.run(installation.cliPath, ["whois", "--json", ip], stdin: nil, timeout: 5),
              result.succeeded, let data = result.stdout.data(using: .utf8),
              let whois = try? JSONDecoder().decode(TailscaleWhois.self, from: data) else {
            return nil
        }
        return whois.UserProfile?.LoginName
    }
}
