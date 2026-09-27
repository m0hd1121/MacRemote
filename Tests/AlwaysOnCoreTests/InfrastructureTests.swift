import XCTest
@testable import AlwaysOnCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class RedactorTests: XCTestCase {
    func testRedactsCredentials() {
        let cases: [(String, String)] = [
            ("using key tskey-auth-kAbC123-XYZdef456", "tskey-auth"),
            ("Authorization: Bearer abcdefghijklmnop", "abcdefghijklmnop"),
            ("password=hunter2 user=bob", "hunter2"),
            ("{\"api_key\": \"sk-12345\"}", "sk-12345"),
            ("visit https://login.tailscale.com/a/1a2b3c4d5e to log in", "1a2b3c4d5e"),
            ("git clone https://bob:s3cret@example.com/repo", "s3cret"),
            ("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAB3Nza\n-----END OPENSSH PRIVATE KEY-----", "AAAAB3Nza"),
        ]
        for (input, secret) in cases {
            let out = Redactor.redact(input)
            XCTAssertFalse(out.contains(secret), "leaked \(secret) in: \(out)")
            XCTAssertTrue(out.contains("REDACTED"), out)
        }
    }

    func testLeavesOrdinaryTextAlone() {
        let text = "Service web crashed with status 1; restarting in 2.0 s"
        XCTAssertEqual(Redactor.redact(text), text)
    }
}

final class RotatingFileWriterTests: XCTestCase {
    func testRotatesAtLimitAndKeepsMaxFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.log")
        let writer = RotatingFileWriter(url: url, maxBytes: 1024, maxFiles: 3)
        let line = String(repeating: "x", count: 99)
        for _ in 0..<100 { writer.write(line: line) }
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertTrue(fm.fileExists(atPath: url.path + ".1"))
        XCTAssertTrue(fm.fileExists(atPath: url.path + ".2"))
        XCTAssertFalse(fm.fileExists(atPath: url.path + ".3"))
        let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(size, 1024)
        let perms = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
        let dirPerms = (try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirPerms, 0o700)
    }

    func testEventLoggerWritesRedactedJSONLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agent.log")
        let logger = EventLogger(fileURL: url, level: .info)
        logger.debug("t", "hidden debug")
        logger.info("t", "token=abc123secret")
        logger.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("hidden debug"))
        XCTAssertFalse(text.contains("abc123secret"))
        let entries = logger.recentEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.level, .info)
    }
}

final class ConfigStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCreatesDefaultsWithPrivatePermissions() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        let result = try store.load()
        XCTAssertEqual(result.configuration, AppConfiguration())
        let perms = (try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
    }

    func testRoundTrip() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        var config = AppConfiguration()
        config.power.batteryMode = .batterySaver
        config.power.batteryThresholdPercent = 42
        config.services = [ServiceSpec(id: "a", name: "A", kind: .command, path: "/bin/sleep", arguments: ["5"], priority: .essential)]
        try store.save(config)
        XCTAssertEqual(try store.load().configuration, config)
    }

    func testMissingKeysFallBackToDefaults() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"power":{"batteryThresholdPercent":50},"services":[{"id":"x","name":"X","kind":"command","path":"/bin/true"}]}"#.utf8).write(to: url)
        let config = try ConfigStore(url: url).load().configuration
        XCTAssertEqual(config.power.batteryThresholdPercent, 50)
        XCTAssertEqual(config.power.batteryMode, PowerSettings().batteryMode)
        XCTAssertEqual(config.tailscale, TailscaleSettings())
        XCTAssertEqual(config.services.first?.restartPolicy, .onCrash)
        XCTAssertEqual(config.services.first?.launchAtStart, true)
    }

    func testCorruptFileIsPreservedAndReset() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data("{ not json".utf8).write(to: url)
        let result = try ConfigStore(url: url).load()
        XCTAssertEqual(result.configuration, AppConfiguration())
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("config.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    func testSanitizeClampsValues() {
        var config = AppConfiguration()
        config.power.batteryThresholdPercent = 0
        config.remoteAccess.webDashboardPort = 80
        config.remoteAccess.restrictedTCPPorts = [22, 22, 70000, 5900]
        config.services = [ServiceSpec(id: "d", name: "A", kind: .command, path: "/bin/true"),
                           ServiceSpec(id: "d", name: "B", kind: .command, path: "/bin/true")]
        let notes = config.sanitize()
        XCTAssertEqual(config.power.batteryThresholdPercent, 5)
        XCTAssertEqual(config.remoteAccess.webDashboardPort, 1024)
        XCTAssertEqual(config.remoteAccess.restrictedTCPPorts, [22, 5900])
        XCTAssertEqual(config.services.count, 1)
        XCTAssertFalse(notes.isEmpty)
    }

    func testServiceValidation() {
        XCTAssertTrue(ServiceSpec(name: "ok", kind: .command, path: "/bin/sh").validationErrors().isEmpty)
        XCTAssertFalse(ServiceSpec(name: "rel", kind: .command, path: "bin/sh").validationErrors().isEmpty)
        XCTAssertFalse(ServiceSpec(name: "dir", kind: .command, path: "/tmp").validationErrors().isEmpty)
        XCTAssertFalse(ServiceSpec(name: "app", kind: .application, path: "/bin/sh").validationErrors().isEmpty)
        XCTAssertEqual(ServiceSpec(id: "../../etc/x", name: "n", kind: .command, path: "/bin/sh").logFileStem, "______etc_x")
    }
}

final class UnixSocketTests: XCTestCase {
    private func socketPath() -> String {
        // Keep well under the 104-byte sun_path limit.
        "/tmp/aoc-\(UUID().uuidString.prefix(8)).sock"
    }

    func testRequestResponseRoundTrip() throws {
        let path = socketPath()
        let server = UnixSocketServer(path: path, permissions: 0o600, authorize: { _ in true }) { data, peer in
            XCTAssertEqual(peer.uid, getuid())
            return Data("echo:".utf8) + data
        }
        try server.start()
        defer { server.stop() }
        let reply = try UnixSocketClient.request(path: path, payload: Data("hi".utf8))
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "echo:hi")
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testUnauthorizedPeerIsRejected() throws {
        let path = socketPath()
        let server = UnixSocketServer(path: path, permissions: 0o600, authorize: { _ in false }) { _, _ in Data("secret".utf8) }
        try server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try UnixSocketClient.request(path: path, payload: Data("hi".utf8), timeoutSeconds: 2))
    }

    func testRefusesToReplaceRegularFile() throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))
        defer { unlink(path) }
        let server = UnixSocketServer(path: path, permissions: 0o600, authorize: { _ in true }) { d, _ in d }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "keep")
    }

    func testTypedAgentProtocol() throws {
        let path = socketPath()
        let server = UnixSocketServer(path: path, permissions: 0o600, authorize: { _ in true }) { data, _ in
            let request = try! JSONCoding.decoder().decode(AgentRequest.self, from: data)
            let response = AgentResponse(ok: request.command == .status, error: nil)
            return try! JSONCoding.encoder().encode(response)
        }
        try server.start()
        defer { server.stop() }
        let response = try AgentClient(socketPath: path).send(AgentRequest(command: .status))
        XCTAssertTrue(response.ok)
    }
}

final class NetworkProbeTests: XCTestCase {
    func testHTTPServerServesAndAuthorizes() throws {
        let port = 20000 + Int.random(in: 0..<20000)
        var allow = true
        let server = StatusHTTPServer(bindAddress: "127.0.0.1", port: port, authorize: { _ in allow }) { req, peer in
            HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: Data("{\"path\":\"\(req.path)\",\"peer\":\"\(peer)\"}".utf8))
        }
        try server.start()
        defer { server.stop() }

        XCTAssertTrue(TCPProbe.connect(host: "127.0.0.1", port: port, timeout: 2).succeeded)
        let body = try httpGet(port: port, path: "/api/status?x=1")
        XCTAssertTrue(body.hasPrefix("HTTP/1.1 200 OK"), body)
        XCTAssertTrue(body.contains("\"path\":\"/api/status\""))
        XCTAssertTrue(body.contains("\"peer\":\"127.0.0.1\""))
        XCTAssertTrue(body.contains("X-Frame-Options: DENY"))

        let post = try httpRaw(port: port, request: "POST / HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(post.hasPrefix("HTTP/1.1 405"), post)

        allow = false
        let denied = try httpGet(port: port, path: "/")
        XCTAssertTrue(denied.hasPrefix("HTTP/1.1 403"), denied)
    }

    func testHTTPServerRefusesWildcardBind() {
        let server = StatusHTTPServer(bindAddress: "0.0.0.0", port: 18080, authorize: { _ in true }) { _, _ in .text(200, "OK", "") }
        XCTAssertThrowsError(try server.start())
    }

    func testRequestLineParsing() {
        XCTAssertEqual(HTTPRequestLine.parse("GET /a?b HTTP/1.1\r\nHost: x\r\n\r\n"), HTTPRequestLine(method: "GET", path: "/a"))
        XCTAssertNil(HTTPRequestLine.parse("GET http://evil/ HTTP/1.1\r\n"))
        XCTAssertNil(HTTPRequestLine.parse("garbage"))
    }

    func testTCPProbeRefusedAndInvalid() {
        // Port 1 on loopback is essentially never listening.
        let result = TCPProbe.connect(host: "127.0.0.1", port: 1, timeout: 1)
        XCTAssertEqual(result, .refused)
        XCTAssertFalse(TCPProbe.connect(host: "not-an-ip", port: 80, timeout: 1).succeeded)
    }

    func testDNSResolvesLocalhost() {
        let result = DNSProbe.resolveIPv4("localhost", timeout: 5)
        XCTAssertTrue(result.addresses.contains("127.0.0.1"), "\(result)")
    }

    private func httpGet(port: Int, path: String) throws -> String {
        try httpRaw(port: port, request: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
    }

    private func httpRaw(port: Int, request: String) throws -> String {
        let fd = socket(AF_INET, POSIX.streamSocketType, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: IPv4Address("127.0.0.1")!.value.bigEndian)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0)
        SocketOptions.setTimeouts(fd, seconds: 5)
        try FrameIO.writeAll(Data(request.utf8), to: fd)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
