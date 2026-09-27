import Foundation
import AlwaysOnCore
import AlwaysOnPlatform

// alwaysonhelper — optional privileged LaunchDaemon (runs as root).
//
// Exactly three operations: report status, toggle `pmset disablesleep` under a lease, and
// load/unload a tailnet-only pf anchor. It accepts connections only from UIDs listed in the
// root-owned allow-list and never executes anything supplied by the client.
//
//   alwaysonhelper               run as daemon (launchd)
//   alwaysonhelper --revert-all  undo everything this helper applied (used by uninstall)
//   alwaysonhelper --version

signal(SIGPIPE, SIG_IGN)
let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print("alwaysonhelper \(Identifiers.version)")
    exit(0)
}

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("alwaysonhelper must run as root (it is installed as a LaunchDaemon).\n".utf8))
    exit(1)
}
umask(0o022)

let logger = EventLogger(fileURL: URL(fileURLWithPath: SystemPaths.helperLog), level: .info,
                         maxFileBytes: 1024 * 1024, maxFiles: 3, echoToStderr: arguments.contains("--revert-all"))

func currentFacts() -> HelperPowerFacts {
    let reading = PowerSourceReader.read()
    return HelperPowerFacts(onBattery: reading.source == .battery, batteryPercent: reading.percent, thermal: ThermalReader.current())
}

let engine = HelperEngine(stateURL: URL(fileURLWithPath: SystemPaths.helperState), runner: ShellRunner(),
                          logger: logger, powerFacts: currentFacts)

if arguments.contains("--revert-all") {
    engine.revertAll()
    logger.flush()
    print("Reverted: disablesleep override and pf anchor (if they were applied by MacAlwaysOn).")
    exit(0)
}

/// Loads the allow-list, refusing it unless it is owned by root and not writable by others.
func loadAuthorizedUIDs() -> Set<UInt32> {
    let path = SystemPaths.helperAuthorizedUIDs
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
          let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
          mode & 0o022 == 0,
          let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        logger.error("helper", "\(path) missing or not root-owned/0644; refusing all clients")
        return []
    }
    return AuthorizedUIDs.parse(text)
}

let authorized = loadAuthorizedUIDs()
logger.info("helper", "Helper \(Identifiers.version) starting; \(authorized.count) authorized user(s)")
engine.startupRecovery()

let server = UnixSocketServer(
    path: SystemPaths.helperSocket,
    // Any local user may connect; the UID check below decides who is served.
    permissions: 0o666,
    authorize: { uid in authorized.contains(UInt32(uid)) },
    handler: { data, peer in
        let response: HelperResponse
        if let request = try? JSONCoding.decoder().decode(HelperRequest.self, from: data) {
            response = engine.handle(request)
            if request.command != .status {
                logger.info("helper", "uid \(peer.uid): \(request.command.rawValue) → \(response.ok ? "ok" : (response.error ?? "error"))")
            }
        } else {
            response = HelperResponse(ok: false, error: "malformed request")
        }
        return (try? JSONCoding.encoder().encode(response)) ?? Data()
    }
)

do {
    try server.start()
} catch {
    logger.error("helper", "Cannot listen on \(SystemPaths.helperSocket): \(error)")
    logger.flush()
    exit(1)
}

// Safety evaluation: on every power-source change and every 30 s (lease expiry, thermal).
let powerMonitor = PowerSourceMonitor { engine.safetyCheck() }
powerMonitor.start()
let safetyTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
safetyTimer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
safetyTimer.setEventHandler { engine.safetyCheck() }
safetyTimer.resume()
let thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                             object: nil, queue: nil) { _ in engine.safetyCheck() }

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        // With the helper gone nothing would enforce the lease or battery floor, so the
        // lid-closed override is withdrawn. The pf anchor is left in place: it only ever
        // restricts access, and `--revert-all` is the explicit undo.
        server.stop()
        engine.releaseLidOverride(reason: "helper stopped")
        logger.info("helper", "Helper stopping")
        logger.flush()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

withExtendedLifetime((powerMonitor, safetyTimer, thermalObserver)) {
    RunLoop.main.run()
}
