#if os(macOS)
import AppKit
import Combine
import Foundation
import AlwaysOnCore

/// The GUI's view of the agent. The GUI never supervises anything itself: it reads status
/// over the agent's Unix socket and edits `config.json`, then asks the agent to reload.
final class AgentStore: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var agentReachable = false
    @Published private(set) var lastContact: Date?
    @Published private(set) var diagnostics: DiagnosticsReport?
    @Published private(set) var runningDiagnostics = false
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var config: AppConfiguration
    @Published var message: String?

    let paths = UserPaths()
    private let client: AgentClient
    private let configStore: ConfigStore
    private let work = DispatchQueue(label: "com.macalwayson.app.agent", qos: .userInitiated)
    private var timer: Timer?

    init() {
        client = AgentClient(socketPath: paths.agentSocket.path)
        configStore = ConfigStore(url: paths.configFile)
        config = (try? configStore.load().configuration) ?? AppConfiguration()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var overallLevel: HealthLevel? {
        guard agentReachable, let snapshot, !snapshot.isStale() else { return nil }
        return snapshot.overall.level
    }

    var menuBarSymbol: String {
        switch overallLevel {
        case .healthy?: return "bolt.horizontal.circle.fill"
        case .degraded?: return "exclamationmark.circle"
        case .unhealthy?: return "xmark.octagon"
        case nil: return "questionmark.circle"
        }
    }

    // MARK: Agent calls

    func refresh() {
        perform(AgentRequest(command: .status)) { _ in }
    }

    func startService(_ id: String) { perform(AgentRequest(command: .startService, serviceID: id)) { _ in } }
    func stopService(_ id: String) { perform(AgentRequest(command: .stopService, serviceID: id)) { _ in } }
    func restartService(_ id: String) { perform(AgentRequest(command: .restartService, serviceID: id)) { _ in } }

    func runDiagnostics() {
        runningDiagnostics = true
        perform(AgentRequest(command: .runDiagnostics), timeout: 90) { [weak self] response in
            self?.runningDiagnostics = false
            if let report = response?.diagnostics { self?.diagnostics = report }
        }
    }

    func loadLogs(limit: Int = 500) {
        perform(AgentRequest(command: .recentLogs, limit: limit)) { [weak self] response in
            if let logs = response?.logs { self?.logs = logs.reversed() }
        }
    }

    private func perform(_ request: AgentRequest, timeout: Int = 10, completion: @escaping (AgentResponse?) -> Void) {
        let client = client
        work.async { [weak self] in
            let result: Result<AgentResponse, Error> = Result { try client.send(request, timeoutSeconds: timeout) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let response):
                    self.agentReachable = true
                    self.lastContact = Date()
                    if let snapshot = response.snapshot { self.snapshot = snapshot }
                    if !response.ok { self.message = response.error }
                    completion(response)
                case .failure:
                    self.agentReachable = false
                    completion(nil)
                }
            }
        }
    }

    // MARK: Configuration

    /// Saves the configuration and tells the agent to apply it. Returns an error message.
    @discardableResult
    func save(_ newConfig: AppConfiguration) -> String? {
        do {
            try configStore.save(newConfig)
            config = (try? configStore.load().configuration) ?? newConfig
        } catch {
            message = "Could not save settings: \(error.localizedDescription)"
            return message
        }
        perform(AgentRequest(command: .reloadConfig)) { [weak self] response in
            if response == nil { self?.message = "Settings saved; the agent is not running, so they apply when it starts." }
        }
        return nil
    }

    func update(_ change: (inout AppConfiguration) -> Void) {
        var copy = config
        change(&copy)
        save(copy)
    }

    // MARK: Agent process

    /// Starts (or restarts) the LaunchAgent and re-enables it at login.
    func restartAgent() {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(Identifiers.agentLabel)"
        let plist = paths.launchAgentPlist.path
        runLaunchctl([["enable", service], ["bootstrap", domain, plist], ["kickstart", "-k", service]],
                     failure: "Could not start the agent. Is it installed? Run Scripts/install.sh.")
    }

    /// Stops the LaunchAgent and keeps it off at future logins until started again here.
    /// Command-line services it supervises are stopped with it; GUI apps keep running.
    func stopAgent() {
        let service = "gui/\(getuid())/\(Identifiers.agentLabel)"
        runLaunchctl([["disable", service], ["bootout", service]], failure: "Could not stop the agent.")
    }

    /// Runs launchctl steps in order. `bootstrap` / `bootout` report an error when the job is
    /// already in the requested state, so only the final step decides success.
    private func runLaunchctl(_ steps: [[String]], failure: String) {
        work.async { [weak self] in
            var last: CommandResult?
            for step in steps {
                last = try? ShellRunner().run(SystemPaths.launchctl, step, timeout: 20)
            }
            DispatchQueue.main.async {
                if last?.succeeded != true, steps.last?.first != "bootout" {
                    self?.message = "\(failure) \(last?.stderr ?? "")"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh() }
            }
        }
    }

    func openLogsFolder() {
        NSWorkspace.shared.open(paths.logsDirectory)
    }

    func openSharingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
