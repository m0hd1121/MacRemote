#if os(macOS)
import SwiftUI
import AlwaysOnCore

@main
struct MacAlwaysOnApp: App {
    @StateObject private var store = AgentStore()

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
    @State private var selection: SidebarSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                AgentBanner()
                switch selection ?? .dashboard {
                case .dashboard: DashboardView()
                case .services: ServicesView()
                case .remoteAccess: RemoteAccessView()
                case .diagnostics: DiagnosticsView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
            .navigationTitle((selection ?? .dashboard).title)
        }
        .alert("MacAlwaysOn", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
    }
}

/// Shown when the agent is unreachable or its data is stale. The GUI never pretends the
/// system is fine when it cannot see it.
struct AgentBanner: View {
    @EnvironmentObject private var store: AgentStore

    var body: some View {
        if !store.agentReachable {
            banner(text: "The background agent is not responding. Always-On is not being enforced and services are not supervised.",
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
            Button("Restart Agent") { store.restartAgent() }
        }
        .padding(10)
        .background(color.opacity(0.12))
    }
}
#endif
