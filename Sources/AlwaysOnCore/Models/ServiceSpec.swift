import Foundation

public enum ServiceKind: String, Codable, CaseIterable, Sendable {
    /// A command-line program launched with `Process`; stdout/stderr go to a rotated log file.
    case command
    /// A macOS `.app` bundle launched through NSWorkspace in the user's session.
    case application
}

/// Used by the power policy to decide what may run under battery / thermal constraints.
public enum ServicePriority: String, Codable, CaseIterable, Sendable {
    /// Kept running in Battery Saver and at low battery.
    case essential
    /// Stopped when the battery policy relaxes.
    case normal
    /// Also stopped under thermal pressure or sustained high CPU on battery.
    case intensive
}

public enum RestartPolicy: String, Codable, CaseIterable, Sendable {
    case never
    /// Restart after a non-zero exit or a signal.
    case onCrash
    /// Restart after any exit that we did not request.
    case always
}

public struct BackoffSettings: Codable, Equatable, Sendable {
    public var baseSeconds: Double = 2
    public var maxSeconds: Double = 300
    public var multiplier: Double = 2
    /// ± fraction of random jitter applied to each delay.
    public var jitterFraction: Double = 0.2
    /// A run this long resets the consecutive-failure counter.
    public var stableAfterSeconds: Double = 60
    /// More restarts than this inside `windowSeconds` marks the service Failed.
    public var maxRestartsInWindow = 10
    public var windowSeconds: Double = 600

    public init() {}

    mutating func sanitize(prefix: String) -> [String] {
        var notes: [String] = []
        func clamp(_ value: inout Double, _ range: ClosedRange<Double>, _ name: String) {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            if clamped != value {
                notes.append("\(prefix): \(name) out of range; using \(clamped)")
                value = clamped
            }
        }
        clamp(&baseSeconds, 0.5...600, "backoff.baseSeconds")
        clamp(&maxSeconds, baseSeconds...86400, "backoff.maxSeconds")
        clamp(&multiplier, 1...10, "backoff.multiplier")
        clamp(&jitterFraction, 0...0.5, "backoff.jitterFraction")
        clamp(&stableAfterSeconds, 1...86400, "backoff.stableAfterSeconds")
        clamp(&windowSeconds, 10...86400, "backoff.windowSeconds")
        let clampedMax = min(max(maxRestartsInWindow, 1), 1000)
        if clampedMax != maxRestartsInWindow {
            notes.append("\(prefix): backoff.maxRestartsInWindow out of range; using \(clampedMax)")
            maxRestartsInWindow = clampedMax
        }
        return notes
    }
}

public struct ServiceSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: ServiceKind
    /// Absolute path to the executable (command) or the `.app` bundle (application).
    public var path: String
    public var arguments: [String]
    public var workingDirectory: String
    /// Extra environment variables for command services. Stored in the 0600 config file;
    /// never logged. Prefer reading secrets from the Keychain inside the service itself.
    public var environment: [String: String]
    public var launchAtStart: Bool
    public var restartPolicy: RestartPolicy
    public var priority: ServicePriority
    /// Wait for a satisfied network path before the first launch.
    public var requiresNetwork: Bool
    /// Optional TCP port on 127.0.0.1 that must accept connections for the service to be healthy.
    public var healthCheckPort: Int?
    public var backoff: BackoffSettings

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: ServiceKind,
        path: String,
        arguments: [String] = [],
        workingDirectory: String = "",
        environment: [String: String] = [:],
        launchAtStart: Bool = true,
        restartPolicy: RestartPolicy = .onCrash,
        priority: ServicePriority = .normal,
        requiresNetwork: Bool = false,
        healthCheckPort: Int? = nil,
        backoff: BackoffSettings = BackoffSettings()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.launchAtStart = launchAtStart
        self.restartPolicy = restartPolicy
        self.priority = priority
        self.requiresNetwork = requiresNetwork
        self.healthCheckPort = healthCheckPort
        self.backoff = backoff
    }

    /// Problems that make the spec unlaunchable. Empty means valid.
    public func validationErrors(fileManager: FileManager = .default) -> [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Name is empty.") }
        if !path.hasPrefix("/") { errors.append("Path must be absolute.") }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        switch kind {
        case .command:
            if !exists || isDirectory.boolValue {
                errors.append("Executable not found at \(path).")
            } else if !fileManager.isExecutableFile(atPath: path) {
                errors.append("\(path) is not executable.")
            }
            if !workingDirectory.isEmpty {
                var wdIsDir: ObjCBool = false
                if !fileManager.fileExists(atPath: workingDirectory, isDirectory: &wdIsDir) || !wdIsDir.boolValue {
                    errors.append("Working directory \(workingDirectory) does not exist.")
                }
            }
        case .application:
            if !path.hasSuffix(".app") { errors.append("Application path must end in .app.") }
            if !exists || !isDirectory.boolValue { errors.append("Application not found at \(path).") }
        }
        if let port = healthCheckPort, !(1...65535).contains(port) {
            errors.append("Health-check port must be 1–65535.")
        }
        return errors
    }

    /// File-name-safe identifier used for per-service log files.
    public var logFileStem: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "service" : String(cleaned.prefix(64))
    }
}

extension BackoffSettings {
    private enum CodingKeys: String, CodingKey {
        case baseSeconds, maxSeconds, multiplier, jitterFraction, stableAfterSeconds, maxRestartsInWindow, windowSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackoffSettings()
        baseSeconds = try c.value(.baseSeconds, default: d.baseSeconds)
        maxSeconds = try c.value(.maxSeconds, default: d.maxSeconds)
        multiplier = try c.value(.multiplier, default: d.multiplier)
        jitterFraction = try c.value(.jitterFraction, default: d.jitterFraction)
        stableAfterSeconds = try c.value(.stableAfterSeconds, default: d.stableAfterSeconds)
        maxRestartsInWindow = try c.value(.maxRestartsInWindow, default: d.maxRestartsInWindow)
        windowSeconds = try c.value(.windowSeconds, default: d.windowSeconds)
    }
}

extension ServiceSpec {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, path, arguments, workingDirectory, environment, launchAtStart
        case restartPolicy, priority, requiresNetwork, healthCheckPort, backoff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ServiceKind.self, forKey: .kind)
        path = try c.decode(String.self, forKey: .path)
        arguments = try c.value(.arguments, default: [])
        workingDirectory = try c.value(.workingDirectory, default: "")
        environment = try c.value(.environment, default: [:])
        launchAtStart = try c.value(.launchAtStart, default: true)
        restartPolicy = try c.value(.restartPolicy, default: .onCrash)
        priority = try c.value(.priority, default: .normal)
        requiresNetwork = try c.value(.requiresNetwork, default: false)
        healthCheckPort = try c.decodeIfPresent(Int.self, forKey: .healthCheckPort)
        backoff = try c.value(.backoff, default: BackoffSettings())
    }
}
