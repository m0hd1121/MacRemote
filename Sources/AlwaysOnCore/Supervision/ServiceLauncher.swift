import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Launches and stops one kind of service. Callbacks may arrive on any queue.
public protocol ServiceLauncher: AnyObject {
    func canLaunch(_ spec: ServiceSpec) -> Bool
    /// Starts the service. `completion` receives the PID or an error. `onExit` fires once
    /// when the launched instance ends (whether or not a stop was requested).
    func launch(_ spec: ServiceSpec, completion: @escaping (Result<Int32, Error>) -> Void,
                onExit: @escaping (_ reason: ExitInfo.Reason, _ code: Int32) -> Void)
    /// Requests a graceful stop, escalating to a forced stop after `grace` seconds.
    func stop(pid: Int32, spec: ServiceSpec, grace: TimeInterval)
    /// Finds an already-running instance to adopt after an agent restart. Returns its PID
    /// and arranges for `onExit` to fire when it ends.
    func adoptExisting(_ spec: ServiceSpec, onExit: @escaping (_ reason: ExitInfo.Reason, _ code: Int32) -> Void) -> Int32?
}

/// Launches command-line programs with Foundation.Process. Portable (macOS and Linux).
public final class CommandLauncher: ServiceLauncher {
    private let paths: UserPaths
    private let logMaxBytes: Int
    private let logMaxFiles: Int
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]

    public init(paths: UserPaths, logMaxBytes: Int = 5 * 1024 * 1024, logMaxFiles: Int = 3) {
        self.paths = paths
        self.logMaxBytes = logMaxBytes
        self.logMaxFiles = logMaxFiles
    }

    public func canLaunch(_ spec: ServiceSpec) -> Bool { spec.kind == .command }

    public func launch(_ spec: ServiceSpec, completion: @escaping (Result<Int32, Error>) -> Void,
                       onExit: @escaping (ExitInfo.Reason, Int32) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.path)
        process.arguments = spec.arguments
        if !spec.workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: spec.workingDirectory, isDirectory: true)
        }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in spec.environment { environment[key] = value }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        do {
            let logURL = paths.serviceLog(for: spec)
            try FilePermissions.ensurePrivateDirectory(logURL.deletingLastPathComponent())
            RotatingFileWriter.rotateIfNeeded(url: logURL, maxBytes: logMaxBytes, maxFiles: logMaxFiles)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                _ = FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: logURL)
            _ = try handle.seekToEnd()
            let banner = "\n=== \(ISO8601DateFormatter().string(from: Date())) starting \(spec.name) ===\n"
            try handle.write(contentsOf: Data(banner.utf8))
            process.standardOutput = handle
            process.standardError = handle

            process.terminationHandler = { [weak self] finished in
                try? handle.close()
                let pid = finished.processIdentifier
                self?.lock.lock()
                self?.processes[pid] = nil
                self?.lock.unlock()
                let reason: ExitInfo.Reason = finished.terminationReason == .uncaughtSignal ? .signaled : .exited
                onExit(reason, finished.terminationStatus)
            }
            try process.run()
            let pid = process.processIdentifier
            lock.lock()
            processes[pid] = process
            lock.unlock()
            completion(.success(pid))
        } catch {
            completion(.failure(error))
        }
    }

    public func stop(pid: Int32, spec: ServiceSpec, grace: TimeInterval) {
        lock.lock()
        let process = processes[pid]
        lock.unlock()
        guard let process, process.isRunning else { return }
        // Signal the whole process group when the child leads one, so helpers it spawned
        // (e.g. `npm start` → node) stop with it instead of being orphaned.
        Self.signal(pid: pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if process.isRunning { Self.signal(pid: pid, SIGKILL) }
        }
    }

    static func signal(pid: Int32, _ sig: Int32) {
        if getpgid(pid) == pid && getpgid(0) != pid {
            _ = killpg(pid, sig)
        } else {
            _ = kill(pid, sig)
        }
    }

    /// Command services cannot be re-attached (we would lose their exit status and output),
    /// so orphans from a previous agent are terminated by the supervisor instead.
    public func adoptExisting(_ spec: ServiceSpec, onExit: @escaping (ExitInfo.Reason, Int32) -> Void) -> Int32? { nil }
}
