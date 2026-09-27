#if os(macOS)
import AppKit
import SwiftUI
import AlwaysOnCore

struct SettingsView: View {
    @EnvironmentObject private var store: AgentStore
    @State private var draft = AppConfiguration()
    @State private var loaded = false
    @State private var allowedLoginsText = ""
    @State private var tcpPortsText = ""
    @State private var udpPortsText = ""

    private var helperInstalled: Bool { store.snapshot?.helper.installed ?? HelperClient().isInstalled }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                alwaysOnSection
                lidSection
                safetySection
                tailscaleSection
                remoteSection
                advancedSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Settings are stored in ~/Library/Application Support/MacAlwaysOn/config.json (private to your user).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { load() }
                Button("Save & Apply") { save() }.keyboardShortcut("s").buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .onAppear { if !loaded { load() } }
    }

    private var alwaysOnSection: some View {
        SwiftUI.Section("Always-On") {
            Toggle("Enable Always-On mode", isOn: $draft.power.alwaysOnEnabled)
            Toggle("Apply on AC power", isOn: $draft.power.acModeEnabled)
            Toggle("Apply on battery", isOn: $draft.power.batteryModeEnabled)
            Picker("Battery behaviour", selection: $draft.power.batteryMode) {
                ForEach(BatteryMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .disabled(!draft.power.batteryModeEnabled)
            Stepper("Battery threshold: \(draft.power.batteryThresholdPercent)%", value: $draft.power.batteryThresholdPercent, in: 5...95)
            Stepper("Re-arm after recovering \(draft.power.hysteresisPercent) points", value: $draft.power.hysteresisPercent, in: 0...20)
            Toggle("Keep the display awake too", isOn: $draft.power.preventDisplaySleep)
            Text(batteryModeExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var batteryModeExplanation: String {
        switch draft.power.batteryMode {
        case .alwaysOn: return "Full Always-On on battery. Below the threshold it switches to Battery Saver (networking + essential services only)."
        case .batterySaver: return "On battery, keep networking alive and run only essential services. Below the threshold, allow normal sleep."
        case .disableBelowThreshold: return "Full Always-On on battery above the threshold; below it, stop non-essential services and allow normal sleep until the battery recovers."
        case .disableAtThreshold: return "Full Always-On until the battery reaches the threshold once; then stay off until AC power returns."
        }
    }

    private var lidSection: some View {
        SwiftUI.Section("Lid closed") {
            Text("Power assertions cannot stop lid-close sleep. Without an external display, staying awake with the lid closed needs the optional privileged helper (pmset disablesleep). It is reverted automatically when Always-On relaxes, at the battery floor, at serious/critical thermal state, or if this agent stops.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Keep running with the lid closed (no external display)", isOn: $draft.power.lidClosedOperation)
                .disabled(!helperInstalled)
            Toggle("Also on battery (generates heat inside a closed laptop)", isOn: $draft.power.lidClosedOnBattery)
                .disabled(!helperInstalled || !draft.power.lidClosedOperation)
            Stepper("Helper battery floor: \(draft.power.helperBatteryFloorPercent)%", value: $draft.power.helperBatteryFloorPercent, in: 10...90)
                .disabled(!helperInstalled)
            if !helperInstalled {
                Text("Helper not installed. Install it with: Scripts/install.sh --with-helper")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var safetySection: some View {
        SwiftUI.Section("Battery & thermal safety") {
            Toggle("Stop non-essential services when the battery policy relaxes", isOn: $draft.power.stopNonEssentialOnLowBattery)
            Stepper("On battery, stop intensive services above \(draft.power.maxCPUPercentOnBattery)% CPU", value: $draft.power.maxCPUPercentOnBattery, in: 10...100, step: 5)
            Picker("Thermal limit", selection: $draft.power.maxThermalLevel) {
                Text("Fair").tag(ThermalLevel.fair)
                Text("Serious").tag(ThermalLevel.serious)
                Text("Critical").tag(ThermalLevel.critical)
            }
            Text("At the thermal limit, intensive services stop and lid-closed operation on battery is withdrawn. At critical, Always-On is suspended entirely.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tailscaleSection: some View {
        SwiftUI.Section("Tailscale") {
            Toggle("Auto-reconnect (relaunch the app; run `tailscale up` if switched off)", isOn: $draft.tailscale.autoReconnect)
            Text("With auto-reconnect on, turning Tailscale off by hand is undone automatically. It never logs in for you and never uses auth keys.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("tailscale CLI path (empty = auto-detect)", text: $draft.tailscale.cliPathOverride)
            Stepper("Check every \(draft.tailscale.statusIntervalSeconds) s while healthy", value: $draft.tailscale.statusIntervalSeconds, in: 15...3600, step: 15)
        }
    }

    private var remoteSection: some View {
        SwiftUI.Section("Remote access") {
            Toggle("Read-only web dashboard on the Tailscale address", isOn: $draft.remoteAccess.webDashboardEnabled)
            Stepper("Web dashboard port: \(draft.remoteAccess.webDashboardPort)", value: $draft.remoteAccess.webDashboardPort, in: 1024...65535)
            TextField("Allowed Tailscale logins (comma-separated; empty = any tailnet device)", text: $allowedLoginsText)
            Toggle("Check SSH availability", isOn: $draft.remoteAccess.probeSSH)
            Toggle("Check Screen Sharing availability", isOn: $draft.remoteAccess.probeScreenSharing)
            Toggle("Restrict ports to Tailscale with pf (needs helper)", isOn: $draft.remoteAccess.restrictPortsToTailnet)
                .disabled(!helperInstalled)
            TextField("Restricted TCP ports", text: $tcpPortsText)
            TextField("Restricted UDP ports", text: $udpPortsText)
        }
    }

    private var advancedSection: some View {
        SwiftUI.Section("Diagnostics & logging") {
            Stepper("Network checks every \(draft.diagnostics.intervalSeconds) s", value: $draft.diagnostics.intervalSeconds, in: 30...3600, step: 30)
            TextField("DNS / Internet probe host", text: $draft.diagnostics.internetProbeHost)
            Picker("Log level", selection: $draft.logging.level) {
                ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
        }
    }

    private func load() {
        draft = store.config
        allowedLoginsText = draft.remoteAccess.webDashboardAllowedLogins.joined(separator: ", ")
        tcpPortsText = draft.remoteAccess.restrictedTCPPorts.map(String.init).joined(separator: ", ")
        udpPortsText = draft.remoteAccess.restrictedUDPPorts.map(String.init).joined(separator: ", ")
        loaded = true
    }

    private func save() {
        var config = draft
        config.remoteAccess.webDashboardAllowedLogins = allowedLoginsText
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        config.remoteAccess.restrictedTCPPorts = Self.ports(tcpPortsText)
        config.remoteAccess.restrictedUDPPorts = Self.ports(udpPortsText)
        config.diagnostics.dnsProbeHost = config.diagnostics.internetProbeHost
        if store.save(config) == nil { load() }
    }

    private static func ports(_ text: String) -> [Int] {
        text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var store: AgentStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(store.overallLevel?.color ?? .gray).frame(width: 10, height: 10)
                Text(headline).font(.headline)
            }
            if let s = store.snapshot, store.agentReachable {
                Text(s.overall.summary.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                Divider()
                line("Power", "\(s.power.source == .battery ? "Battery \(s.power.batteryPercent.map { "\($0)%" } ?? "")" : "AC") · \(s.power.policy.mode.rawValue)")
                line("Lid", s.power.lid.rawValue)
                line("Tailscale", s.tailscale.connected ? (s.tailscale.dnsName ?? s.tailscale.ipv4 ?? "connected") : "disconnected")
                line("Services", "\(s.services.filter { $0.state == .running }.count) of \(s.services.count) running")
            } else {
                Text("The background agent is not responding.").font(.caption).foregroundStyle(.red)
            }
            Divider()
            Toggle("Always-On", isOn: Binding(
                get: { store.config.power.alwaysOnEnabled },
                set: { value in store.update { $0.power.alwaysOnEnabled = value } }
            ))
            HStack {
                Button("Open Dashboard") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            Text("Quitting this window does not stop the agent.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { store.refresh() }
    }

    private var headline: String {
        guard store.agentReachable, let s = store.snapshot else { return "Agent not running" }
        return "MacAlwaysOn · \(s.overall.level.rawValue.capitalized)"
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value)
        }
        .font(.callout)
    }
}
#endif
