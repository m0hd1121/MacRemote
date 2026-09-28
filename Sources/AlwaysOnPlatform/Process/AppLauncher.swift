#if os(macOS)
import AppKit
import AlwaysOnCore

/// Launches `.app` bundles in the user's session through NSWorkspace and watches them with
/// KVO on `NSRunningApplication.isTerminated`.
public final class AppLauncher: ServiceLauncher {
    private var observations: [Int32: NSKeyValueObservation] = [:]
    private let lock = NSLock()

    public init() {}

    public func canLaunch(_ spec: ServiceSpec) -> Bool { spec.kind == .application }

    public func launch(_ spec: ServiceSpec, completion: @escaping (Result<Int32, Error>) -> Void,
                       onExit: @escaping (ExitInfo.Reason, Int32) -> Void) {
        let url = URL(fileURLWithPath: spec.path, isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = false
        configuration.arguments = spec.arguments
        if !spec.environment.isEmpty { configuration.environment = spec.environment }

        DispatchQueue.main.async { [weak self] in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                guard let app else {
                    completion(.failure(error ?? NSError(domain: "MacAlwaysOn", code: 1,
                                                         userInfo: [NSLocalizedDescriptionKey: "NSWorkspace could not open \(spec.path)"])))
                    return
                }
                self?.observe(app, onExit: onExit)
                completion(.success(app.processIdentifier))
            }
        }
    }

    public func stop(pid: Int32, spec: ServiceSpec, grace: TimeInterval) {
        DispatchQueue.main.async {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + grace) {
                if !app.isTerminated { app.forceTerminate() }
            }
        }
    }

    public func adoptExisting(_ spec: ServiceSpec, onExit: @escaping (ExitInfo.Reason, Int32) -> Void) -> Int32? {
        guard let bundleID = Bundle(url: URL(fileURLWithPath: spec.path))?.bundleIdentifier else { return nil }
        let target = URL(fileURLWithPath: spec.path).standardizedFileURL.path
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        let match = candidates.first { $0.bundleURL?.standardizedFileURL.path == target } ?? candidates.first
        guard let app = match else { return nil }
        observe(app, onExit: onExit)
        return app.processIdentifier
    }

    private func observe(_ app: NSRunningApplication, onExit: @escaping (ExitInfo.Reason, Int32) -> Void) {
        let pid = app.processIdentifier
        let fired = OneShot()
        let observation = app.observe(\.isTerminated, options: [.initial, .new]) { [weak self] observed, _ in
            guard observed.isTerminated, fired.claim() else { return }
            self?.lock.lock()
            self?.observations[pid] = nil
            self?.lock.unlock()
            // NSRunningApplication exposes no exit status; the supervisor decides whether
            // this was requested or unexpected.
            onExit(.vanished, 0)
        }
        lock.lock()
        if !fired.isClaimed { observations[pid] = observation }
        lock.unlock()
    }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}
#endif
