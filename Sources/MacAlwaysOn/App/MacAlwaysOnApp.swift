#if os(macOS)
import SwiftUI
import AlwaysOnCore

@main
struct MacAlwaysOnApp: App {
    @StateObject private var store = AgentStore()

    init() {
        AppLog.write("MacAlwaysOn \(Identifiers.version) launching on \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    var body: some Scene {
        Window("MacAlwaysOn", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 760)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            Image(systemName: store.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard, services, remoteAccess, diagnostics, logs, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .services: return "Services"
        case .remoteAccess: return "Remote Access"
        case .diagnostics: return "Diagnostics"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .services: return "square.stack.3d.up"
        case .remoteAccess: return "network"
        case .diagnostics: return "stethoscope"
        case .logs: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: AgentStore
    @State private var selection: SidebarSection = .dashboard

    // A plain two-pane layout rather than NavigationSplitView: the split view rendered an
    // empty window when this app (built with an older SDK) ran on macOS 27.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                AgentBanner()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("MacAlwaysOn — \(selection.title)")
        .onAppear { AppLog.write("main window appeared") }
        .alert("MacAlwaysOn", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    Label(section.title, systemImage: section.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == section ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selection == section ? Color.accentColor : Color.clear)
                )
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(store.overallLevel?.color ?? .gray).frame(width: 8, height: 8)
                Text(store.agentReachable ? "Agent running" : "Agent stopped")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            Button(store.agentReachable ? "Stop Background Agent" : "Start Background Agent") {
                if store.agentReachable { store.stopAgent() } else { store.restartAgent() }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .help("The agent keeps the Mac awake and your services running. Stopping it also keeps it off at login until you start it again.")
        }
        .padding(10)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard: DashboardView()
        case .services: ServicesView()
        case .remoteAccess: RemoteAccessView()
        case .diagnostics: DiagnosticsView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}

/// Minimal launch diagnostics written to stderr and ~/Library/Logs/MacAlwaysOn/app.log,
/// so a blank or hung window can be diagnosed without a debugger.
enum AppLog {
    private static let url = UserPaths().logsDirectory.appendingPathComponent("app.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        try? FilePermissions.ensurePrivateDirectory(url.deletingLastPathComponent())
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            _ = FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}

/// Shown when the agent is unreachable or its data is stale. The GUI never pretends the
/// system is fine when it cannot see it.
struct AgentBanner: View {
    @EnvironmentObject private var store: AgentStore

    var body: some View {
        if !store.agentReachable {
            banner(text: "The background agent is not running. Always-On is not being enforced and services are not supervised.",
                   color: .red)
        } else if let snapshot = store.snapshot, snapshot.isStale() {
            banner(text: "The agent's last report is \(Formatting.duration(Date().timeIntervalSince(snapshot.generatedAt))) old; data shown may be out of date.",
                   color: .orange)
        }
    }

    private func banner(text: String, color: Color) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Start Agent") { store.restartAgent() }
        }
        .padding(10)
        .background(color.opacity(0.12))
    }
}
#endif
