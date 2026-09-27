import Foundation

public enum AgentCommand: String, Codable, Sendable {
    case status
    case reloadConfig
    case startService
    case stopService
    case restartService
    case runDiagnostics
    case recentLogs
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public var command: AgentCommand
    public var serviceID: String?
    public var limit: Int?

    public init(command: AgentCommand, serviceID: String? = nil, limit: Int? = nil) {
        self.command = command
        self.serviceID = serviceID
        self.limit = limit
    }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var snapshot: StatusSnapshot?
    public var diagnostics: DiagnosticsReport?
    public var logs: [LogEntry]?

    public init(ok: Bool, error: String? = nil, snapshot: StatusSnapshot? = nil,
                diagnostics: DiagnosticsReport? = nil, logs: [LogEntry]? = nil) {
        self.ok = ok
        self.error = error
        self.snapshot = snapshot
        self.diagnostics = diagnostics
        self.logs = logs
    }

    public static func failure(_ message: String) -> AgentResponse { AgentResponse(ok: false, error: message) }
}

/// Client used by the GUI and the `alwaysond --status/--diagnose` CLI.
public struct AgentClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: AgentRequest, timeoutSeconds: Int = 10) throws -> AgentResponse {
        try UnixSocketClient.request(path: socketPath, request, as: AgentResponse.self, timeoutSeconds: timeoutSeconds)
    }
}
