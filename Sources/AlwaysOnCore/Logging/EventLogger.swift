import Foundation
#if canImport(os)
import os
#endif

public struct LogEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var level: LogLevel
    public var category: String
    public var message: String

    public init(timestamp: Date, level: LogLevel, category: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Structured JSON-lines logger with rotation, redaction and an in-memory tail for the UI.
/// Also mirrors to the unified log on Apple platforms (`log show --predicate 'subsystem == "com.macalwayson"'`).
public final class EventLogger {
    public static let subsystem = "com.macalwayson"

    private let writer: RotatingFileWriter?
    private let queue = DispatchQueue(label: "com.macalwayson.logger")
    private var recent: [LogEntry] = []
    private let recentCapacity: Int
    private var minimumLevel: LogLevel
    private let echoToStderr: Bool
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(fileURL: URL?, level: LogLevel = .info, maxFileBytes: Int = 2 * 1024 * 1024, maxFiles: Int = 5,
                recentCapacity: Int = 500, echoToStderr: Bool = false) {
        writer = fileURL.map { RotatingFileWriter(url: $0, maxBytes: maxFileBytes, maxFiles: maxFiles) }
        minimumLevel = level
        self.recentCapacity = recentCapacity
        self.echoToStderr = echoToStderr
    }

    public func setLevel(_ level: LogLevel) {
        queue.sync { minimumLevel = level }
    }

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: Redactor.redact(message))
        queue.async { [self] in
            guard level >= minimumLevel else { return }
            recent.append(entry)
            if recent.count > recentCapacity { recent.removeFirst(recent.count - recentCapacity) }
            if let data = try? encoder.encode(entry) {
                var line = data
                line.append(0x0A)
                writer?.write(line)
            }
            if echoToStderr {
                FileHandle.standardError.write(Data("[\(level.rawValue)] \(category): \(entry.message)\n".utf8))
            }
            #if canImport(os)
            let osLogger = Logger(subsystem: Self.subsystem, category: category)
            switch level {
            case .debug: osLogger.debug("\(entry.message, privacy: .public)")
            case .info: osLogger.info("\(entry.message, privacy: .public)")
            case .warning: osLogger.warning("\(entry.message, privacy: .public)")
            case .error: osLogger.error("\(entry.message, privacy: .public)")
            }
            #endif
        }
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    public func recentEntries(limit: Int) -> [LogEntry] {
        queue.sync { Array(recent.suffix(max(0, limit))) }
    }

    /// Blocks until queued entries are written (used on shutdown and in tests).
    public func flush() {
        queue.sync {}
    }
}
