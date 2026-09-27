import Foundation

/// Client for the optional root helper. All calls are cheap no-ops if it is not installed.
public struct HelperClient: Sendable {
    public var socketPath: String
    public var plistPath: String

    public init(socketPath: String = SystemPaths.helperSocket, plistPath: String = SystemPaths.helperPlist) {
        self.socketPath = socketPath
        self.plistPath = plistPath
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath) || FileManager.default.fileExists(atPath: socketPath)
    }

    public func send(_ request: HelperRequest, timeoutSeconds: Int = 20) throws -> HelperResponse {
        try UnixSocketClient.request(path: socketPath, request, as: HelperResponse.self, timeoutSeconds: timeoutSeconds)
    }

    public func status() -> HelperStatus {
        var status = HelperStatus()
        status.installed = isInstalled
        guard status.installed else { return status }
        do {
            let response = try send(HelperRequest(command: .status), timeoutSeconds: 5)
            status.reachable = true
            status.state = response.state
            status.error = response.ok ? nil : response.error
        } catch {
            status.error = "Helper installed but not reachable: \(error)"
        }
        return status
    }
}
