import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ProbeResult: Equatable, Sendable {
    case success(latencyMs: Int)
    case refused
    case timedOut
    case failed(String)

    public var succeeded: Bool {
        if case .success = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .success(let ms): return "reachable (\(ms) ms)"
        case .refused: return "connection refused (nothing listening)"
        case .timedOut: return "timed out (filtered or host unreachable)"
        case .failed(let message): return message
        }
    }
}

public enum TCPProbe {
    /// Non-blocking IPv4 TCP connect with a timeout. No data is sent.
    public static func connect(host: String, port: Int, timeout: TimeInterval) -> ProbeResult {
        guard let ip = IPv4Address(host) else { return .failed("\(host) is not an IPv4 address") }
        guard (1...65535).contains(port) else { return .failed("invalid port \(port)") }
        let fd = socket(AF_INET, POSIX.streamSocketType, 0)
        guard fd >= 0 else { return .failed("socket: \(POSIX.errnoDescription)") }
        defer { POSIX.closeFD(fd) }
        SocketOptions.setCloseOnExec(fd)
        SocketOptions.disableSigpipe(fd)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: ip.value.bigEndian)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let start = Date()
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        if rc == 0 { return .success(latencyMs: Int(Date().timeIntervalSince(start) * 1000)) }
        if errno == ECONNREFUSED { return .refused }
        guard errno == EINPROGRESS else { return .failed("connect: \(POSIX.errnoDescription)") }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let waitMs = Int32(max(1, min(timeout, 60)) * 1000)
        let ready = poll(&pfd, 1, waitMs)
        if ready == 0 { return .timedOut }
        if ready < 0 { return .failed("poll: \(POSIX.errnoDescription)") }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        switch soError {
        case 0: return .success(latencyMs: Int(Date().timeIntervalSince(start) * 1000))
        case ECONNREFUSED: return .refused
        case ETIMEDOUT: return .timedOut
        default: return .failed("connect: \(String(cString: strerror(soError)))")
        }
    }
}

public enum DNSProbe {
    public struct Result: Equatable, Sendable {
        public var addresses: [String]
        public var error: String?
        public var succeeded: Bool { !addresses.isEmpty }
    }

    /// Resolves IPv4 addresses with getaddrinfo on a background thread, bounded by `timeout`.
    public static func resolveIPv4(_ host: String, timeout: TimeInterval) -> Result {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.set(resolveBlocking(host))
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            return Result(addresses: [], error: "DNS lookup for \(host) timed out after \(Int(timeout)) s")
        }
        return box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Result(addresses: [], error: "not resolved")
        func set(_ v: Result) { lock.lock(); value = v; lock.unlock() }
        func get() -> Result { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func resolveBlocking(_ host: String) -> Result {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = POSIX.streamSocketType
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &list)
        guard rc == 0, let first = list else {
            return Result(addresses: [], error: "DNS lookup for \(host) failed: \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(list) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let sa = entry.pointee.ai_addr, Int32(sa.pointee.sa_family) == AF_INET {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let text = IPv4Address(ip).description
                if !addresses.contains(text) { addresses.append(text) }
            }
            cursor = entry.pointee.ai_next
        }
        return Result(addresses: addresses, error: nil)
    }
}
