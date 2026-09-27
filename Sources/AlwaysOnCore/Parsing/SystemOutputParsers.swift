import Foundation

/// Parses `pmset -g` (current settings) into `name → value`.
/// Lines look like ` sleep                1 (sleep prevented by powerd)` or ` SleepDisabled		1`.
public enum PMSetParser {
    public static func settings(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.first == " " || line.first == "\t" else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            let key = String(fields[0])
            if result[key] == nil { result[key] = String(fields[1]) }
        }
        return result
    }

    public static func sleepDisabled(_ output: String) -> Bool? {
        settings(output)["SleepDisabled"].map { $0 == "1" }
    }

    /// Parses the "Assertion status system-wide:" block of `pmset -g assertions`.
    public static func systemWideAssertions(_ output: String) -> [String: Int] {
        var result: [String: Int] = [:]
        var inBlock = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("Assertion status system-wide") {
                inBlock = true
                continue
            }
            if inBlock {
                guard line.first == " " || line.first == "\t" else { break }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count == 2, let value = Int(fields[1]) { result[String(fields[0])] = value }
            }
        }
        return result
    }
}

public enum ListenerExposure: String, Codable, Sendable {
    case loopback, tailscale, wildcard, lan
}

public struct ListeningSocket: Codable, Equatable, Sendable {
    public var proto: String
    public var address: String
    public var port: Int
    public var exposure: ListenerExposure
}

/// Parses `netstat -an -p tcp` LISTEN lines. Unlike lsof, netstat shows sockets of all
/// users (including root-owned sshd / screensharingd) without privileges.
public enum NetstatParser {
    public static func listeners(_ output: String) -> [ListeningSocket] {
        var result: [ListeningSocket] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 6, fields.last == "LISTEN", fields[0].hasPrefix("tcp") else { continue }
            let local = fields[3]
            guard let dot = local.lastIndex(of: "."), let port = Int(local[local.index(after: dot)...]) else { continue }
            var address = String(local[..<dot])
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
            let socket = ListeningSocket(proto: fields[0], address: address, port: port, exposure: classify(address))
            if !result.contains(socket) { result.append(socket) }
        }
        return result
    }

    public static func classify(_ address: String) -> ListenerExposure {
        if address == "*" || address == "0.0.0.0" || address == "::" || address == "*.*" { return .wildcard }
        if let v4 = IPv4Address(address) {
            if v4.isLoopback { return .loopback }
            if v4.isTailscale { return .tailscale }
            return .lan
        }
        if IPv6Classifier.isLoopback(address) { return .loopback }
        if IPv6Classifier.isTailscale(address) { return .tailscale }
        return .lan
    }
}

/// Parses `route -n get default` for the gateway line.
public enum RouteParser {
    public static func defaultGateway(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                let value = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

/// Parses the reference token printed by `pfctl -E` ("Token : 12345").
public enum PFCtlParser {
    public static func enableToken(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("Token") {
            let parts = line.split(separator: ":")
            if parts.count == 2 {
                let token = parts[1].trimmingCharacters(in: .whitespaces)
                if !token.isEmpty, token.allSatisfy(\.isNumber) { return token }
            }
        }
        return nil
    }

    /// True when the main ruleset evaluates sub-anchors of `com.apple/*`.
    public static func hasAppleAnchor(_ rulesOutput: String) -> Bool {
        rulesOutput.contains("anchor \"com.apple/*\"")
    }
}
