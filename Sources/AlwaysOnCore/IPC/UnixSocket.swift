import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case system(String, Int32)
    case frameTooLarge(Int)
    case connectionClosed
    case notASocket(String)
    case unauthorized(uid_t)

    public var description: String {
        switch self {
        case .pathTooLong(let path): return "socket path too long: \(path)"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        case .frameTooLarge(let size): return "frame of \(size) bytes exceeds limit"
        case .connectionClosed: return "connection closed"
        case .notASocket(let path): return "\(path) exists and is not a socket; refusing to replace it"
        case .unauthorized(let uid): return "peer uid \(uid) is not authorized"
        }
    }
}

/// Length-prefixed frames: 4-byte big-endian length followed by the payload.
public enum FrameIO {
    public static let maxFrameBytes = 4 * 1024 * 1024

    public static func write(_ payload: Data, to fd: Int32) throws {
        guard payload.count <= maxFrameBytes else { throw SocketError.frameTooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        try writeAll(frame, to: fd)
    }

    public static func read(from fd: Int32) throws -> Data {
        let header = try readExactly(4, from: fd)
        let length = header.withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            memcpy(&value, raw.baseAddress!, 4)
            return UInt32(bigEndian: value)
        }
        guard Int(length) <= maxFrameBytes else { throw SocketError.frameTooLarge(Int(length)) }
        return try readExactly(Int(length), from: fd)
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                #if canImport(Darwin)
                let written = Darwin.write(fd, pointer, remaining)
                #else
                let written = send(fd, pointer, remaining, Int32(MSG_NOSIGNAL))
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.system("write", errno)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    static func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                #else
                return Glibc.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                #endif
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("read", errno)
            }
            if n == 0 { throw SocketError.connectionClosed }
            offset += n
        }
        return buffer
    }
}

enum SocketAddress {
    static func unix(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return addr
    }
}

enum SocketOptions {
    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    static func disableSigpipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func setCloseOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// UID of the process on the other end of a connected Unix socket.
    static func peerUID(_ fd: Int32) -> uid_t? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        #else
        // struct ucred is only exposed by Glibc under _GNU_SOURCE; mirror its layout.
        struct PeerCredentials { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }
        var cred = PeerCredentials()
        var len = socklen_t(MemoryLayout<PeerCredentials>.size)
        return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0 ? cred.uid : nil
        #endif
    }
}

public struct PeerInfo: Sendable {
    public let uid: uid_t
}

/// Minimal request/response server on a Unix domain socket: one framed request and one
/// framed response per connection. Peers are authorized by UID before any bytes are read.
public final class UnixSocketServer {
    public typealias Handler = (Data, PeerInfo) -> Data

    public let path: String
    private let permissions: mode_t
    private let authorize: (uid_t) -> Bool
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.macalwayson.socket.accept")
    private let workQueue = DispatchQueue(label: "com.macalwayson.socket.work", attributes: .concurrent)
    private let connectionLimit = DispatchSemaphore(value: 8)

    public init(path: String, permissions: mode_t, authorize: @escaping (uid_t) -> Bool, handler: @escaping Handler) {
        self.path = path
        self.permissions = permissions
        self.authorize = authorize
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        try removeStaleSocket()
        let fd = socket(AF_UNIX, POSIX.streamSocketType, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        SocketOptions.setCloseOnExec(fd)
        var addr = try SocketAddress.unix(path)
        // Create the socket with no permissions, then open it up to exactly `permissions`,
        // so there is no window in which it is more permissive than intended.
        let oldMask = umask(0o777)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0 else {
            let code = errno
            POSIX.closeFD(fd)
            throw SocketError.system("bind", code)
        }
        guard chmod(path, permissions) == 0, listen(fd, 16) == 0 else {
            let code = errno
            POSIX.closeFD(fd)
            unlink(path)
            throw SocketError.system("listen", code)
        }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { POSIX.closeFD(fd) }
        source = src
        src.resume()
    }

    public func stop() {
        guard let src = source else { return }
        source = nil
        src.cancel()
        listenFD = -1
        unlink(path)
    }

    private func removeStaleSocket() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw SocketError.notASocket(path) }
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        SocketOptions.setCloseOnExec(client)
        SocketOptions.disableSigpipe(client)
        SocketOptions.setTimeouts(client, seconds: 5)
        guard let uid = SocketOptions.peerUID(client), authorize(uid) else {
            POSIX.closeFD(client)
            return
        }
        guard connectionLimit.wait(timeout: .now()) == .success else {
            POSIX.closeFD(client)
            return
        }
        workQueue.async { [handler, connectionLimit] in
            defer {
                POSIX.closeFD(client)
                connectionLimit.signal()
            }
            guard let request = try? FrameIO.read(from: client) else { return }
            let response = handler(request, PeerInfo(uid: uid))
            try? FrameIO.write(response, to: client)
        }
    }
}

public enum UnixSocketClient {
    public static func request(path: String, payload: Data, timeoutSeconds: Int = 10) throws -> Data {
        let fd = socket(AF_UNIX, POSIX.streamSocketType, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        defer { POSIX.closeFD(fd) }
        SocketOptions.setCloseOnExec(fd)
        SocketOptions.disableSigpipe(fd)
        SocketOptions.setTimeouts(fd, seconds: timeoutSeconds)
        var addr = try SocketAddress.unix(path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SocketError.system("connect", errno) }
        try FrameIO.write(payload, to: fd)
        return try FrameIO.read(from: fd)
    }

    public static func request<Request: Encodable, Response: Decodable>(
        path: String, _ request: Request, as: Response.Type, timeoutSeconds: Int = 10
    ) throws -> Response {
        let data = try JSONCoding.encoder().encode(request)
        let reply = try Self.request(path: path, payload: data, timeoutSeconds: timeoutSeconds)
        return try JSONCoding.decoder().decode(Response.self, from: reply)
    }
}
