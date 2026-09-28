import XCTest
@testable import AlwaysOnCore

final class TailscaleParserTests: XCTestCase {
    static let runningJSON = """
    {
      "Version": "1.76.1-t123",
      "BackendState": "Running",
      "AuthURL": "",
      "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1234"],
      "Self": {
        "HostName": "macbook",
        "DNSName": "macbook.tail1234.ts.net.",
        "OS": "macOS",
        "Online": true,
        "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1234"]
      },
      "Health": [],
      "MagicDNSSuffix": "tail1234.ts.net",
      "CurrentTailnet": {"Name": "me@example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": true},
      "Peer": {
        "nodekey:aa": {"HostName": "phone", "DNSName": "phone.tail1234.ts.net.", "Online": true, "TailscaleIPs": ["100.64.0.2"]},
        "nodekey:bb": {"HostName": "desktop", "DNSName": "desktop.tail1234.ts.net.", "Online": false, "TailscaleIPs": ["100.64.0.3"]}
      }
    }
    """

    func testParsesRunningStatus() throws {
        let s = try TailscaleStatusParser.parse(Data(Self.runningJSON.utf8))
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.ipv4, "100.101.102.103")
        XCTAssertEqual(s.ipv6, "fd7a:115c:a1e0::1234")
        XCTAssertEqual(s.dnsName, "macbook.tail1234.ts.net")
        XCTAssertEqual(s.hostName, "macbook")
        XCTAssertEqual(s.tailnetName, "me@example.com")
        XCTAssertEqual(s.peerCount, 2)
        XCTAssertEqual(s.onlinePeerCount, 1)
        XCTAssertEqual(s.version, "1.76.1-t123")
    }

    func testParsesStoppedStatusWithMissingFields() throws {
        let s = try TailscaleStatusParser.parse(Data(#"{"BackendState":"Stopped","Self":{"HostName":"mac"}}"#.utf8))
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(s.backendState, "Stopped")
        XCTAssertNil(s.ipv4)
        XCTAssertEqual(s.peerCount, 0)
    }

    func testExplanationsAreActionable() {
        XCTAssertTrue(TailscaleStatusParser.explain(backendState: "NeedsLogin").contains("sign in"))
        XCTAssertTrue(TailscaleStatusParser.explain(backendState: nil).contains("not"))
    }
}

final class SystemParserTests: XCTestCase {
    func testPMSetSettings() {
        let output = """
        System-wide power settings:
         SleepDisabled		1
        Currently in use:
         standby              1
         Sleep On Power Button 1
         womp                 1
         autorestart          0
         sleep                1 (sleep prevented by powerd, caffeinate)
         hibernatemode        3
         displaysleep         10
        """
        let settings = PMSetParser.settings(output)
        XCTAssertEqual(settings["SleepDisabled"], "1")
        XCTAssertEqual(settings["autorestart"], "0")
        XCTAssertEqual(settings["sleep"], "1")
        XCTAssertEqual(settings["displaysleep"], "10")
        XCTAssertEqual(PMSetParser.sleepDisabled(output), true)
        XCTAssertNil(PMSetParser.sleepDisabled("Currently in use:\n sleep 1\n"))
    }

    func testPMSetAssertions() {
        let output = """
        Assertion status system-wide:
           BackgroundTask                 0
           ApplePushServiceTask           0
           PreventUserIdleDisplaySleep    0
           PreventSystemSleep             1
           PreventUserIdleSystemSleep     1
        Listed by owning process:
           pid 123(alwaysond): [0x0001] 00:01:00 PreventUserIdleSystemSleep named: "MacAlwaysOn"
        """
        let a = PMSetParser.systemWideAssertions(output)
        XCTAssertEqual(a["PreventUserIdleSystemSleep"], 1)
        XCTAssertEqual(a["PreventSystemSleep"], 1)
        XCTAssertEqual(a["PreventUserIdleDisplaySleep"], 0)
        XCTAssertNil(a["pid"])
    }

    func testNetstatListeners() {
        let output = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  100.101.102.103.8686   *.*                    LISTEN
        tcp46      0      0  *.22                   *.*                    LISTEN
        tcp4       0      0  *.5900                 *.*                    LISTEN
        tcp4       0      0  127.0.0.1.631          *.*                    LISTEN
        tcp6       0      0  ::1.631                *.*                    LISTEN
        tcp4       0      0  192.168.1.20.3000      *.*                    LISTEN
        tcp4       0      0  192.168.1.20.52000     17.1.1.1.443           ESTABLISHED
        """
        let l = NetstatParser.listeners(output)
        XCTAssertEqual(l.count, 6)
        XCTAssertEqual(l.first { $0.port == 8686 }?.exposure, .tailscale)
        XCTAssertEqual(l.first { $0.port == 22 }?.exposure, .wildcard)
        XCTAssertEqual(l.first { $0.port == 3000 }?.exposure, .lan)
        XCTAssertTrue(l.filter { $0.port == 631 }.allSatisfy { $0.exposure == .loopback })
    }

    func testRouteGateway() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
        """
        XCTAssertEqual(RouteParser.defaultGateway(output), "192.168.1.1")
        XCTAssertNil(RouteParser.defaultGateway("route: writing to routing socket: not in table"))
    }

    func testPFCtlToken() {
        XCTAssertEqual(PFCtlParser.enableToken("No ALTQ support in kernel\npf enabled\nToken : 18446744073709551615\n"), "18446744073709551615")
        XCTAssertNil(PFCtlParser.enableToken("pfctl: permission denied"))
        XCTAssertTrue(PFCtlParser.hasAppleAnchor("scrub-anchor \"com.apple/*\" all fragments reassemble\nanchor \"com.apple/*\" all\n"))
    }
}

final class IPAddressTests: XCTestCase {
    func testParsingAndClassification() {
        XCTAssertEqual(IPv4Address("100.64.0.1")?.isTailscale, true)
        XCTAssertEqual(IPv4Address("100.127.255.255")?.isTailscale, true)
        XCTAssertEqual(IPv4Address("100.128.0.1")?.isTailscale, false)
        XCTAssertEqual(IPv4Address("127.0.0.1")?.isLoopback, true)
        XCTAssertEqual(IPv4Address("192.168.0.4")?.isPrivateLAN, true)
        XCTAssertNil(IPv4Address("256.1.1.1"))
        XCTAssertNil(IPv4Address("1.2.3"))
        XCTAssertNil(IPv4Address("1.2.3.4.5"))
        XCTAssertNil(IPv4Address("a.b.c.d"))
        XCTAssertEqual(IPv4Address("10.1.2.3")?.description, "10.1.2.3")
        XCTAssertTrue(IPv6Classifier.isTailscale("fd7a:115c:a1e0:ab12::1"))
    }

    func testInterfaceHelpers() {
        let list = [
            InterfaceAddress(interface: "lo0", address: "127.0.0.1", isIPv6: false),
            InterfaceAddress(interface: "en0", address: "192.168.1.20", isIPv6: false),
            InterfaceAddress(interface: "utun4", address: "100.101.102.103", isIPv6: false),
            InterfaceAddress(interface: "en0", address: "169.254.3.3", isIPv6: false),
        ]
        XCTAssertEqual(InterfaceAddresses.localIPv4(from: list), ["192.168.1.20"])
        XCTAssertEqual(InterfaceAddresses.tailscaleIPv4(from: list), "100.101.102.103")
        XCTAssertFalse(InterfaceAddresses.current().isEmpty, "loopback at least")
    }
}

extension TailscaleParserTests {
    func testStatusSurroundedByWarningLines() throws {
        let noisy = "Warning: client version \"1.90.1\" != tailscaled server version \"1.90.0\"\n" + Self.runningJSON + "\n"
        let json = try XCTUnwrap(TailscaleStatusParser.extractJSONObject(noisy))
        XCTAssertEqual(try TailscaleStatusParser.parse(Data(json.utf8)).ipv4, "100.101.102.103")
    }

    func testUnexpectedFieldTypesDoNotBreakParsing() throws {
        let odd = #"{"BackendState":"Running","Health":null,"Peer":null,"CurrentTailnet":null,"Version":3,"# +
            #""TailscaleIPs":["100.106.10.29"],"Self":{"HostName":"mac","Online":"yes","DNSName":"mac.ts.net."}}"#
        let s = try TailscaleStatusParser.parse(Data(odd.utf8))
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.ipv4, "100.106.10.29")
        XCTAssertEqual(s.dnsName, "mac.ts.net")
        XCTAssertNil(s.version)
        XCTAssertEqual(s.peerCount, 0)
    }

    func testNoJSONYieldsNil() {
        XCTAssertNil(TailscaleStatusParser.extractJSONObject("The Tailscale GUI failed to start"))
    }
}

extension TailscaleMonitorTests {
    func testUnreadableOutputReportsSnippet() {
        let junk = CommandResult(status: 0, stdout: "something unexpected", stderr: "", timedOut: false)
        let monitor = TailscaleMonitor(settings: TailscaleSettings(), logger: EventLogger(fileURL: nil), runner: FakeRunner([junk]),
                                       environment: nil, locate: { _ in TailscaleInstallation(cliPath: "/x", variant: .openSource, appBundleID: nil) })
        XCTAssertTrue(monitor.checkNow().lastError?.contains("something unexpected") ?? false)
    }
}

extension DiagnosticsTests {
    func testClamshellFlagAloneIsNotTrustedOnBattery() {
        var s = StatusSnapshot(generatedAt: Date(), refreshIntervalSeconds: 15, agent: AgentInfo(version: "1", pid: 1, startedAt: Date()))
        s.power.source = .battery
        s.power.lid = .open
        s.power.clamshellCausesSleep = false
        s.power.systemSleepDisabled = false
        s.system.externalDisplayConnected = false
        let check = DiagnosticsEngine.evaluate(s, context: DiagnosticsContext()).checks.first { $0.id == "power.lidCapable" }
        XCTAssertEqual(check?.outcome, .warning)
    }
}
