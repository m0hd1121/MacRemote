#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AlwaysOnCore

struct ServicesView: View {
    @EnvironmentObject private var store: AgentStore
    @State private var editing: ServiceSpec?
    @State private var isNew = false

    var body: some View {
        List {
            if store.config.services.isEmpty {
                Text("No services yet. Add an application, script or server that should keep running.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
            ForEach(store.config.services) { spec in
                ServiceRow(spec: spec, status: store.snapshot?.services.first { $0.id == spec.id },
                           edit: {
                               isNew = false
                               editing = spec
                           })
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isNew = true
                    editing = ServiceSpec(name: "", kind: .application, path: "")
                } label: {
                    Label("Add Service", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { spec in
            ServiceEditor(spec: spec, isNew: isNew) { result in
                editing = nil
                guard let result else { return }
                switch result {
                case .save(let updated):
                    store.update { config in
                        if let index = config.services.firstIndex(where: { $0.id == updated.id }) {
                            config.services[index] = updated
                        } else {
                            config.services.append(updated)
                        }
                    }
                case .delete(let id):
                    store.update { $0.services.removeAll { $0.id == id } }
                }
            }
        }
    }
}

private struct ServiceRow: View {
    @EnvironmentObject private var store: AgentStore
    let spec: ServiceSpec
    let status: ServiceStatus?
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: spec.kind == .application ? "app" : "terminal")
                Text(spec.name).font(.headline)
                StateBadge(text: status?.state.label ?? "Unknown", color: status?.state.color ?? .secondary)
                Text(spec.priority.rawValue).font(.caption).foregroundStyle(.secondary)
                if status?.healthy == false { StateBadge(text: "Health check failing", color: .orange) }
                Spacer()
                Button("Start") { store.startService(spec.id) }
                    .disabled(status?.state == .running || status?.state == .starting)
                Button("Stop") { store.stopService(spec.id) }
                    .disabled(status?.state != .running && status?.state != .starting && status?.state != .restarting)
                Button("Restart") { store.restartService(spec.id) }
                Button("Edit…", action: edit)
            }
            Text(spec.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 18) {
                metric("PID", status?.pid.map(String.init) ?? "—")
                metric("CPU", Formatting.percent(status?.cpuPercent))
                metric("Memory", Formatting.bytes(status?.memoryBytes))
                metric("Restarts", "\(status?.restartCount ?? 0)")
                metric("Last launch", dateText(status?.lastLaunchAt))
                metric("Last crash", dateText(status?.lastCrashAt))
            }
            if let note = status?.note ?? status?.lastExitDescription.map({ "Last exit: \($0)" }) {
                Text(note).font(.caption).foregroundStyle(status?.state == .failed ? .red : .secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption)
        }
    }
}

enum ServiceEditorResult {
    case save(ServiceSpec)
    case delete(String)
}

struct ServiceEditor: View {
    @State private var spec: ServiceSpec
    @State private var argumentsText: String
    @State private var environmentText: String
    @State private var healthPortText: String
    let isNew: Bool
    let done: (ServiceEditorResult?) -> Void

    init(spec: ServiceSpec, isNew: Bool, done: @escaping (ServiceEditorResult?) -> Void) {
        _spec = State(initialValue: spec)
        _argumentsText = State(initialValue: spec.arguments.joined(separator: "\n"))
        _environmentText = State(initialValue: spec.environment.keys.sorted().map { "\($0)=\(spec.environment[$0] ?? "")" }.joined(separator: "\n"))
        _healthPortText = State(initialValue: spec.healthCheckPort.map(String.init) ?? "")
        self.isNew = isNew
        self.done = done
    }

    private var built: ServiceSpec {
        var s = spec
        s.arguments = argumentsText.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        var env: [String: String] = [:]
        for line in environmentText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty {
                env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1]
            }
        }
        s.environment = env
        s.healthCheckPort = Int(healthPortText.trimmingCharacters(in: .whitespaces))
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        return s
    }

    var body: some View {
        let errors = built.validationErrors()
        VStack(alignment: .leading, spacing: 0) {
            Form {
                SwiftUI.Section("What to run") {
                    TextField("Name", text: $spec.name)
                    Picker("Kind", selection: $spec.kind) {
                        Text("Application (.app)").tag(ServiceKind.application)
                        Text("Command / script").tag(ServiceKind.command)
                    }
                    HStack {
                        TextField(spec.kind == .application ? "Application path" : "Executable path", text: $spec.path)
                        Button("Choose…") { choosePath() }
                    }
                    LabeledContent("Arguments (one per line)") {
                        TextEditor(text: $argumentsText).font(.body.monospaced()).frame(height: 60)
                    }
                    if spec.kind == .command {
                        TextField("Working directory (optional)", text: $spec.workingDirectory)
                    }
                    LabeledContent("Environment (KEY=value per line)") {
                        TextEditor(text: $environmentText).font(.body.monospaced()).frame(height: 50)
                    }
                    Text("Environment values are stored in the private config file (mode 0600) and never logged. Keep real secrets in the Keychain and read them from your service.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SwiftUI.Section("Supervision") {
                    Toggle("Launch automatically", isOn: $spec.launchAtStart)
                    Picker("Restart", selection: $spec.restartPolicy) {
                        Text("Never").tag(RestartPolicy.never)
                        Text("On crash").tag(RestartPolicy.onCrash)
                        Text("Always (any exit)").tag(RestartPolicy.always)
                    }
                    Picker("Priority", selection: $spec.priority) {
                        Text("Essential — keep on low battery").tag(ServicePriority.essential)
                        Text("Normal").tag(ServicePriority.normal)
                        Text("Intensive — stop under heat / high CPU").tag(ServicePriority.intensive)
                    }
                    Toggle("Wait for network before first launch", isOn: $spec.requiresNetwork)
                    TextField("Health-check TCP port on 127.0.0.1 (optional)", text: $healthPortText)
                    Stepper("Give up after \(spec.backoff.maxRestartsInWindow) restarts in \(Int(spec.backoff.windowSeconds / 60)) min",
                            value: $spec.backoff.maxRestartsInWindow, in: 1...100)
                }
            }
            .formStyle(.grouped)

            if !errors.isEmpty {
                VStack(alignment: .leading) {
                    ForEach(errors, id: \.self) { Text("• \($0)").foregroundStyle(.red).font(.callout) }
                }
                .padding(.horizontal, 20)
            }

            HStack {
                if !isNew {
                    Button("Delete Service", role: .destructive) { done(.delete(spec.id)) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { done(.save(built)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!errors.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 620, height: 720)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = spec.kind == .command
        if spec.kind == .application {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
        }
        if panel.runModal() == .OK, let url = panel.url {
            spec.path = url.path
            if spec.name.isEmpty { spec.name = url.deletingPathExtension().lastPathComponent }
        }
    }
}
#endif
