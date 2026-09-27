#if os(macOS)
import Foundation
import Network
import AlwaysOnCore

public struct NetworkPathInfo: Equatable, Sendable {
    public var satisfied: Bool
    public var interfaces: [String]
    public var primaryType: String?
}

/// Wraps NWPathMonitor: event-driven notification of connectivity changes (Wi-Fi
/// reconnects, cable unplugged, VPN interface changes).
public final class NetworkPathMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.macalwayson.network.path")
    private let handler: (NetworkPathInfo) -> Void
    private var last: NetworkPathInfo?

    public init(handler: @escaping (NetworkPathInfo) -> Void) {
        self.handler = handler
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let info = NetworkPathInfo(
                satisfied: path.status == .satisfied,
                interfaces: path.availableInterfaces.map { "\(Self.typeName($0.type)):\($0.name)" },
                primaryType: path.availableInterfaces.first.map { Self.typeName($0.type) }
            )
            guard info != self.last else { return }
            self.last = info
            self.handler(info)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }

    static func typeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .wiredEthernet: return "ethernet"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "other"
        }
    }
}

/// NSWorkspace-based host hooks for the Tailscale monitor.
public final class WorkspaceTailscaleEnvironment: TailscaleHostEnvironment {
    private let runner: CommandRunning

    public init(runner: CommandRunning = ShellRunner()) {
        self.runner = runner
    }

    public func isAppRunning(bundleID: String) -> Bool {
        !NSRunningApplicationLookup.running(bundleID: bundleID).isEmpty
    }

    public func launchApp(bundleID: String) -> Bool {
        // `open -g -b` launches in the background without stealing focus.
        (try? runner.run(SystemPaths.open, ["-g", "-b", bundleID], timeout: 15).succeeded) ?? false
    }
}
#endif
