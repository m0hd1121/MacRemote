import Foundation

/// Subset of `tailscale status --json` that we use. All fields optional: the schema is
/// stable but older clients omit some keys.
public struct TailscaleStatusJSON: Decodable, Sendable {
    public struct Node: Decodable, Sendable {
        public var HostName: String?
        public var DNSName: String?
        public var OS: String?
        public var Online: Bool?
        public var TailscaleIPs: [String]?
    }

    public struct Tailnet: Decodable, Sendable {
        public var Name: String?
        public var MagicDNSSuffix: String?
        public var MagicDNSEnabled: Bool?
    }

    public var Version: String?
    public var BackendState: String?
    public var TailscaleIPs: [String]?
    public var `Self`: Node?
    public var Health: [String]?
    public var MagicDNSSuffix: String?
    public var CurrentTailnet: Tailnet?
    public var Peer: [String: Node]?
}

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
    public static func parse(_ data: Data) throws -> TailscaleParsedStatus {
        let raw = try JSONDecoder().decode(TailscaleStatusJSON.self, from: data)
        let ips = raw.TailscaleIPs ?? raw.`Self`?.TailscaleIPs ?? []
        let ipv4 = ips.first { IPv4Address($0) != nil }
        let ipv6 = ips.first { $0.contains(":") }
        var dnsName = raw.`Self`?.DNSName
        if let name = dnsName, name.hasSuffix(".") { dnsName = String(name.dropLast()) }
        let peers = raw.Peer.map { Array($0.values) } ?? []
        return TailscaleParsedStatus(
            version: raw.Version,
            backendState: raw.BackendState,
            ipv4: ipv4,
            ipv6: ipv6,
            hostName: raw.`Self`?.HostName,
            dnsName: dnsName?.isEmpty == true ? nil : dnsName,
            tailnetName: raw.CurrentTailnet?.Name,
            magicDNSSuffix: raw.CurrentTailnet?.MagicDNSSuffix ?? raw.MagicDNSSuffix,
            selfOnline: raw.`Self`?.Online,
            peerCount: peers.count,
            onlinePeerCount: peers.filter { $0.Online == true }.count,
            health: raw.Health ?? []
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
