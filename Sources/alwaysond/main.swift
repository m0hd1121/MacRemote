import AppKit
import Foundation
import AlwaysOnCore

// alwaysond — MacAlwaysOn LaunchAgent.
//
//   alwaysond               run the agent (launchd does this)
//   alwaysond --status      print the running agent's status
//   alwaysond --diagnose    run diagnostics in the running agent and print the report
//   alwaysond --json        with --status / --diagnose: print JSON
//   alwaysond --version

signal(SIGPIPE, SIG_IGN)

let arguments = Set(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")

func printErr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func query(_ request: AgentRequest, timeout: Int) -> AgentResponse {
    let client = AgentClient(socketPath: UserPaths().agentSocket.path)
    do {
        let response = try client.send(request, timeoutSeconds: timeout)
        guard response.ok else {
            printErr("Agent error: \(response.error ?? "unknown")")
            exit(1)
        }
        return response
    } catch {
        printErr("The MacAlwaysOn agent is not running or not reachable (\(error)).")
        printErr("Start it with: launchctl kickstart -k gui/\(getuid())/\(Identifiers.agentLabel)")
        exit(2)
    }
}

func printJSON<T: Encodable>(_ value: T) {
    if let data = try? JSONCoding.encoder(pretty: true).encode(value) {
        print(String(decoding: data, as: UTF8.self))
    }
}

if arguments.contains("--version") {
    print("alwaysond \(Identifiers.version)")
    exit(0)
}

if arguments.contains("--status") {
    guard let s = query(AgentRequest(command: .status), timeout: 10).snapshot else { exit(1) }
    if json {
        printJSON(s)
    } else {
        print("Overall:      \(s.overall.level.rawValue) — \(s.overall.summary.joined(separator: "; "))")
        print("Power:        \(s.power.source.rawValue)\(s.power.batteryPercent.map { " \($0)%" } ?? ""), lid \(s.power.lid.rawValue), mode \(s.power.policy.mode.rawValue)")
        print("Assertions:   idle-sleep \(s.power.assertions.idleSleepPrevented ? "held" : "not held"), system-sleep \(s.power.assertions.systemSleepPrevented ? "held" : "not held"), SleepDisabled \(s.power.systemSleepDisabled.map { $0 ? "1" : "0" } ?? "?")")
        print("Network:      \(s.network.pathSatisfied ? "up" : "down") \(s.network.interfaces.joined(separator: ", "))")
        print("Tailscale:    \(s.tailscale.connected ? "connected \(s.tailscale.dnsName ?? "") \(s.tailscale.ipv4 ?? "")" : (s.tailscale.lastError ?? "disconnected"))")
        print("SSH:          \(s.remoteAccess.ssh.detail)")
        print("Screen Share: \(s.remoteAccess.screenSharing.detail)")
        print("Web:          \(s.remoteAccess.webDashboard.detail)")
        for svc in s.services {
            print("Service:      \(svc.name) — \(svc.state.rawValue)\(svc.pid.map { " pid \($0)" } ?? "") restarts \(svc.restartCount)")
        }
    }
    exit(0)
}

if arguments.contains("--diagnose") {
    guard let report = query(AgentRequest(command: .runDiagnostics), timeout: 90).diagnostics else { exit(1) }
    if json {
        printJSON(report)
    } else {
        for category in DiagnosticCategory.allCases {
            let checks = report.checks.filter { $0.category == category }
            guard !checks.isEmpty else { continue }
            print("\n== \(category.displayName) ==")
            for check in checks {
                let mark: String
                switch check.outcome {
                case .pass: mark = "PASS"
                case .info: mark = "INFO"
                case .warning: mark = "WARN"
                case .fail: mark = "FAIL"
                }
                print("[\(mark)] \(check.title): \(check.detail)")
                if let remedy = check.remedy { print("       → \(remedy)") }
            }
        }
    }
    exit(report.worstOutcome == .fail ? 1 : 0)
}

// Agent mode. NSApplication gives us a main run loop that services IOKit, NSWorkspace
// and KVO callbacks; the activation policy keeps the agent out of the Dock.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

let controller = AgentController()
controller.start()

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        controller.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

application.run()
