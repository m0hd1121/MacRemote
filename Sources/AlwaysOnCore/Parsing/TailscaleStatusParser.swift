import Foundation

public struct TailscaleParsedStatus: Equatable, Sendable {
    public var version: String?
    public var backendState: String?
    public var ipv4: String?
    public var ipv6: String?
    public var hostName: String?
    public var dnsName: String?
    public var tailnetName: String?
    public var magicDNSSuffix: String?
    public var selfOnline: Bool?
    public var peerCount: Int
    public var onlinePeerCount: Int
    public var health: [String]

    public var isRunning: Bool { backendState == "Running" }
}

public enum TailscaleStatusParser {
    public enum ParseError: Error, CustomStringConvertible {
        case notAnObject

        public var description: String { "status JSON is not an object" }
    }

    /// Returns the outermost `{ … }` in `text`, ignoring any warning lines the CLI prints
    /// around it (e.g. client/daemon version mismatch notices).
    public static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }

    /// Parsed with JSONSerialization rather than Codable so an unexpected type in a field we
    /// do not rely on can never make the whole status unreadable.
    public static func parse(_ data: Data) throws -> TailscaleParsedStatus {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notAnObject }
        let me = root["Self"] as? [String: Any]
        let ips = (root["TailscaleIPs"] as? [String]) ?? (me?["TailscaleIPs"] as? [String]) ?? []
        let tailnet = root["CurrentTailnet"] as? [String: Any]
        var dnsName = me?["DNSName"] as? String
        if let name = dnsName, name.hasSuffix(".") { dnsName = String(name.dropLast()) }
        let peers = (root["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        let health = (root["Health"] as? [Any])?.compactMap { $0 as? String } ?? []
        return TailscaleParsedStatus(
            version: root["Version"] as? String,
            backendState: root["BackendState"] as? String,
            ipv4: ips.first { IPv4Address($0) != nil },
            ipv6: ips.first { $0.contains(":") },
            hostName: me?["HostName"] as? String,
            dnsName: dnsName?.isEmpty == true ? nil : dnsName,
            tailnetName: tailnet?["Name"] as? String,
            magicDNSSuffix: (tailnet?["MagicDNSSuffix"] as? String) ?? (root["MagicDNSSuffix"] as? String),
            selfOnline: me?["Online"] as? Bool,
            peerCount: peers.count,
            onlinePeerCount: peers.filter { ($0["Online"] as? Bool) == true }.count,
            health: health
        )
    }

    /// Plain-language meaning of a BackendState value.
    public static func explain(backendState: String?) -> String {
        switch backendState {
        case "Running": return "Connected to the tailnet."
        case "Starting": return "Tailscale is starting."
        case "Stopped": return "Tailscale is installed but switched off (disconnected)."
        case "NeedsLogin": return "Tailscale needs you to log in again (the node key expired or was logged out). This cannot be fixed automatically: open the Tailscale app and sign in."
        case "NeedsMachineAuth": return "This Mac is waiting for an administrator to approve it in the Tailscale admin console."
        case "NoState", nil: return "Tailscale has not reported a state (the daemon or app may not be running)."
        case let other?: return "Tailscale state: \(other)."
        }
    }
}

/// `tailscale whois --json <ip>` subset, used to identify web dashboard visitors.
public struct TailscaleWhois: Decodable, Sendable {
    public struct Profile: Decodable, Sendable {
        public var LoginName: String?
        public var DisplayName: String?
    }

    public struct WhoisNode: Decodable, Sendable {
        public var Name: String?
        public var ComputedName: String?
    }

    public var UserProfile: Profile?
    public var Node: WhoisNode?
}
