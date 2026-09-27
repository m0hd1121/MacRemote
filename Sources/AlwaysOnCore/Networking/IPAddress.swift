import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct IPv4Address: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let octet = UInt8(part) else { return nil }
            result = result << 8 | UInt32(octet)
        }
        value = result
    }

    public var description: String {
        "\(value >> 24 & 0xff).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
    }

    public var isLoopback: Bool { IPv4Network.loopback.contains(self) }
    public var isTailscale: Bool { IPv4Network.tailscaleCGNAT.contains(self) }
    public var isPrivateLAN: Bool { IPv4Network.privateRanges.contains { $0.contains(self) } }
    public var isLinkLocal: Bool { IPv4Network.linkLocal.contains(self) }
}

public struct IPv4Network: Equatable, Sendable {
    public let address: IPv4Address
    public let prefix: Int

    public init?(_ cidr: String) {
        let pieces = cidr.split(separator: "/")
        guard pieces.count == 2, let addr = IPv4Address(String(pieces[0])), let prefix = Int(pieces[1]), (0...32).contains(prefix) else {
            return nil
        }
        self.address = addr
        self.prefix = prefix
    }

    public var mask: UInt32 { prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix)) }

    public func contains(_ ip: IPv4Address) -> Bool {
        (ip.value & mask) == (address.value & mask)
    }

    public static let tailscaleCGNAT = IPv4Network("100.64.0.0/10")!
    public static let loopback = IPv4Network("127.0.0.0/8")!
    public static let linkLocal = IPv4Network("169.254.0.0/16")!
    public static let privateRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].compactMap(IPv4Network.init)
}

public enum IPv6Classifier {
    public static func isTailscale(_ address: String) -> Bool {
        address.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    public static func isLoopback(_ address: String) -> Bool {
        address == "::1"
    }
}

public struct InterfaceAddress: Equatable, Sendable {
    public var interface: String
    public var address: String
    public var isIPv6: Bool
}

public enum InterfaceAddresses {
    /// All IPv4/IPv6 addresses of interfaces that are up, via getifaddrs(3).
    public static func current() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var results: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0 else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == AF_INET ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var address = String(cString: host)
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
            results.append(InterfaceAddress(interface: name, address: address, isIPv6: family == AF_INET6))
        }
        return results
    }

    /// Non-loopback, non-link-local, non-Tailscale IPv4 addresses (the "local IP").
    public static func localIPv4(from list: [InterfaceAddress]) -> [String] {
        list.filter { !$0.isIPv6 }
            .compactMap { IPv4Address($0.address) }
            .filter { !$0.isLoopback && !$0.isTailscale && !$0.isLinkLocal }
            .map(\.description)
    }

    /// Tailscale IPv4 found on a local interface (utunN on macOS, tailscale0 on Linux).
    public static func tailscaleIPv4(from list: [InterfaceAddress]) -> String? {
        list.first { !$0.isIPv6 && (IPv4Address($0.address)?.isTailscale ?? false) }?.address
    }
}
