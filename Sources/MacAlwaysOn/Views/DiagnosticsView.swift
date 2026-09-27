#if os(macOS)
import SwiftUI
import AlwaysOnCore

struct DiagnosticsView: View {
    @EnvironmentObject private var store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let report = store.diagnostics {
                    Label("Last run \(dateText(report.generatedAt))", systemImage: report.worstOutcome.symbol)
                        .foregroundStyle(report.worstOutcome.color)
                } else {
                    Text("Run diagnostics to test power, network, Tailscale, remote access, services and exposure.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.runningDiagnostics { ProgressView().controlSize(.small) }
                Button("Run Diagnostics") { store.runDiagnostics() }
                    .disabled(store.runningDiagnostics || !store.agentReachable)
            }
            .padding(16)
            Divider()
            List {
                if !store.agentReachable {
                    checkRow(DiagnosticsEngine.agentUnavailableCheck(lastSnapshot: store.snapshot))
                }
                if let report = store.diagnostics {
                    ForEach(DiagnosticCategory.allCases, id: \.self) { category in
                        let checks = report.checks.filter { $0.category == category }
                        if !checks.isEmpty {
                            SwiftUI.Section(category.displayName) {
                                ForEach(checks) { checkRow($0) }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if store.diagnostics == nil && store.agentReachable { store.runDiagnostics() }
        }
    }

    private func checkRow(_ check: DiagnosticCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.outcome.symbol).foregroundStyle(check.outcome.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).font(.headline)
                Text(check.detail).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let remedy = check.remedy {
                    Text(remedy).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct LogsView: View {
    @EnvironmentObject private var store: AgentStore
    @State private var minimumLevel: LogLevel = .info
    @State private var filter = ""

    private var entries: [LogEntry] {
        store.logs.filter { entry in
            entry.level >= minimumLevel && (filter.isEmpty || entry.message.localizedCaseInsensitiveContains(filter) || entry.category.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Level", selection: $minimumLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .frame(width: 180)
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button("Refresh") { store.loadLogs() }
                Button("Open Logs Folder") { store.openLogsFolder() }
            }
            .padding(12)
            Divider()
            List(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(dateText(entry.timestamp)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    Text(entry.level.rawValue.uppercased()).font(.caption.monospaced().bold())
                        .foregroundStyle(color(entry.level)).frame(width: 64, alignment: .leading)
                    Text(entry.category).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Text(entry.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Logs are redacted (tokens, passwords, keys) and rotated automatically. Service output: ~/Library/Logs/MacAlwaysOn/services/")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .onAppear { store.loadLogs() }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
#endif
