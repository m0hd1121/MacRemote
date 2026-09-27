import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct HTTPResponse: Sendable {
    public var status: Int
    public var reason: String
    public var contentType: String
    public var body: Data

    public init(status: Int, reason: String, contentType: String = "text/plain; charset=utf-8", body: Data) {
        self.status = status
        self.reason = reason
        self.contentType = contentType
        self.body = body
    }

    public static func text(_ status: Int, _ reason: String, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, body: Data((message + "\n").utf8))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

public struct HTTPRequestLine: Equatable, Sendable {
    public var method: String
    public var path: String

    /// Parses `GET /path HTTP/1.1` from the head of a request. Query strings are dropped.
    public static func parse(_ head: String) -> HTTPRequestLine? {
        guard let firstLine = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? head.split(separator: "\n").first else {
            return nil
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        guard path.hasPrefix("/") else { return nil }
        return HTTPRequestLine(method: String(parts[0]), path: path)
    }
}

/// Tiny read-only HTTP/1.1 server bound to ONE specific IPv4 address (the Tailscale IP).
/// It never binds to 0.0.0.0. Every connection is checked by `authorize(peerIP)` first.
public final class StatusHTTPServer {
    public typealias Router = (_ request: HTTPRequestLine, _ peerIP: String) -> HTTPResponse

    public let bindAddress: String
    public let port: Int
    private let authorize: (String) -> Bool
    private let router: Router
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.macalwayson.http.accept")
    private let workQueue = DispatchQueue(label: "com.macalwayson.http.work", attributes: .concurrent)
    private let connectionLimit = DispatchSemaphore(value: 8)

    public init(bindAddress: String, port: Int, authorize: @escaping (String) -> Bool, router: @escaping Router) {
        self.bindAddress = bindAddress
        self.port = port
        self.authorize = authorize
        self.router = router
    }

    deinit { stop() }

    public var isRunning: Bool { source != nil }

    public func start() throws {
        guard let ip = IPv4Address(bindAddress) else { throw SocketError.system("bind (invalid address \(bindAddress))", EINVAL) }
        guard ip.value != 0 else { throw SocketError.system("bind (refusing wildcard address)", EINVAL) }
        let fd = socket(AF_INET, POSIX.streamSocketType, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        SocketOptions.setCloseOnExec(fd)
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: ip.value.bigEndian)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            POSIX.closeFD(fd)
            throw SocketError.system("bind \(bindAddress):\(port)", code)
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
    }

    private func acceptOne() {
        var peer = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &len) }
        }
        guard client >= 0 else { return }
        SocketOptions.setCloseOnExec(client)
        SocketOptions.disableSigpipe(client)
        SocketOptions.setTimeouts(client, seconds: 5)
        let peerIP = IPv4Address(UInt32(bigEndian: peer.sin_addr.s_addr)).description

        guard connectionLimit.wait(timeout: .now()) == .success else {
            POSIX.closeFD(client)
            return
        }
        workQueue.async { [authorize, router, connectionLimit] in
            defer {
                POSIX.closeFD(client)
                connectionLimit.signal()
            }
            let response: HTTPResponse
            if !authorize(peerIP) {
                response = .text(403, "Forbidden", "Forbidden")
            } else if let head = Self.readHead(client), let line = HTTPRequestLine.parse(head) {
                if line.method == "GET" || line.method == "HEAD" {
                    var r = router(line, peerIP)
                    if line.method == "HEAD" { r.body = Data() }
                    response = r
                } else {
                    response = .text(405, "Method Not Allowed", "Only GET is supported; this dashboard is read-only.")
                }
            } else {
                response = .text(400, "Bad Request", "Bad Request")
            }
            try? FrameIO.writeAll(response.serialized(), to: client)
        }
    }

    /// Reads until the end of the request head (blank line), capped at 8 KiB.
    private static func readHead(_ fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.count < 8192 {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, raw.baseAddress!, raw.count)
                #else
                return Glibc.read(fd, raw.baseAddress!, raw.count)
                #endif
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.range(of: terminator) != nil { break }
        }
        guard !buffer.isEmpty else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}
