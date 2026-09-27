#if os(macOS)
import SwiftUI
import AlwaysOnCore

struct DashboardView: View {
    @EnvironmentObject private var store: AgentStore

    private let columns = [GridItem(.adaptive(minimum: 330), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            if let s = store.snapshot {
                VStack(alignment: .leading, spacing: 16) {
                    overall(s)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        powerCard(s)
                        tailscaleCard(s)
                        remoteCard(s)
                        servicesCard(s)
                        networkCard(s)
                        systemCard(s)
                    }
                }
                .padding(20)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No status yet").font(.title3)
                    Text("Waiting for the MacAlwaysOn agent. If this persists, install it with Scripts/install.sh.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 400)
            }
        }
    }

    private func overall(_ s: StatusSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(s.overall.level.color).frame(width: 14, height: 14).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.overall.level.rawValue.capitalized).font(.title2.weight(.semibold))
                Text(s.overall.summary.joined(separator: " · ")).foregroundStyle(.secondary)
                Text("Updated \(dateText(s.generatedAt)) · agent \(s.agent.version), up \(Formatting.duration(Date().timeIntervalSince(s.agent.startedAt)))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("Always-On", isOn: Binding(
                get: { store.config.power.alwaysOnEnabled },
                set: { value in store.update { $0.power.alwaysOnEnabled = value } }
            ))
            .toggleStyle(.switch)
        }
    }

    private func powerCard(_ s: StatusSnapshot) -> some View {
        let p = s.power
        return Card(title: "Power", symbol: p.source == .battery ? "battery.75" : "powerplug") {
            InfoRow("Source", p.source == .battery ? "Battery" : (p.source == .ac ? "AC power" : p.source.rawValue.uppercased()))
            if p.hasBattery {
                InfoRow("Battery", "\(p.batteryPercent.map { "\($0)%" } ?? "—")\(p.isCharging == true ? " · charging" : (p.isCharged == true ? " · charged" : ""))")
                if let minutes = p.timeRemainingMinutes { InfoRow("Time remaining", Formatting.duration(Double(minutes) * 60)) }
                if let health = p.batteryHealth { InfoRow("Battery health", health + (p.cycleCount.map { " · \($0) cycles" } ?? "")) }
            }
            InfoRow("Always-On mode", modeText(p.policy.mode), tint: p.policy.mode == .relaxed ? .orange : nil)
            InfoRow("Lid", p.lid == .notPresent ? "No lid" : p.lid.rawValue.capitalized)
            InfoRow("Lid close sleeps Mac", p.systemSleepDisabled == true ? "No (sleep disabled by helper)" : yesNo(p.clamshellCausesSleep),
                    tint: (p.clamshellCausesSleep == true && p.systemSleepDisabled != true && p.lid != .notPresent) ? .orange : nil)
            InfoRow("Sleep status", "Awake (agent reporting)")
            InfoRow("Idle sleep", p.assertions.idleSleepPrevented ? "Prevented" : "Allowed")
            if let wake = p.lastWakeAt { InfoRow("Last wake", dateText(wake)) }
            if let reason = p.policy.reasons.last {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tailscaleCard(_ s: StatusSnapshot) -> some View {
        let t = s.tailscale
        return Card(title: "Tailscale", symbol: "point.3.connected.trianglepath.dotted") {
            if !t.installed {
                Text("Tailscale is not installed. Remote access requires it.").foregroundStyle(.red)
                Link("Download Tailscale for Mac", destination: URL(string: "https://tailscale.com/download/mac")!)
            } else {
                InfoRow("Status", t.connected ? "Connected" : (t.backendState ?? "Not responding"), tint: t.connected ? .green : .red)
                InfoRow("Tailscale IP", t.ipv4 ?? "—")
                InfoRow("Hostname", t.dnsName ?? t.hostName ?? "—")
                InfoRow("Tailnet", t.tailnetName ?? "—")
                InfoRow("Peers online", "\(t.onlinePeerCount) of \(t.peerCount)")
                InfoRow("Last connected", dateText(t.lastConnectedAt))
                InfoRow("Variant", t.variant.rawValue)
                if let error = t.lastError, !t.connected {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func remoteCard(_ s: StatusSnapshot) -> some View {
        let r = s.remoteAccess
        return Card(title: "Remote Access (Tailscale only)", symbol: "lock.shield") {
            InfoRow("Host", r.tailscaleHost ?? "—")
            InfoRow("IP", r.tailscaleIP ?? "—")
            InfoRow("SSH", availability(r.ssh), tint: tint(r.ssh))
            InfoRow("Remote Desktop", availability(r.screenSharing), tint: tint(r.screenSharing))
            InfoRow("Web dashboard", availability(r.webDashboard), tint: tint(r.webDashboard))
            InfoRow("Tailnet-only firewall", r.firewallRestricted == true ? "Active" : (r.firewallRestricted == false ? "Off" : "Helper not installed"))
        }
    }

    private func servicesCard(_ s: StatusSnapshot) -> some View {
        Card(title: "Services", symbol: "square.stack.3d.up") {
            if s.services.isEmpty {
                Text("No services configured.").foregroundStyle(.secondary)
            }
            ForEach(s.services) { svc in
                HStack {
                    Text(svc.name)
                    Spacer()
                    if let cpu = svc.cpuPercent { Text(Formatting.percent(cpu)).font(.caption).foregroundStyle(.secondary) }
                    StateBadge(text: svc.state.label, color: svc.state.color)
                }
            }
        }
    }

    private func networkCard(_ s: StatusSnapshot) -> some View {
        let n = s.network
        return Card(title: "Network", symbol: "wifi") {
            InfoRow("Connection", n.pathSatisfied ? (n.primaryInterfaceType?.capitalized ?? "Connected") : "Disconnected", tint: n.pathSatisfied ? nil : .red)
            InfoRow("Interfaces", n.interfaces.isEmpty ? "—" : n.interfaces.joined(separator: ", "))
            InfoRow("Local IP", n.localIPv4.isEmpty ? "—" : n.localIPv4.joined(separator: ", "))
            InfoRow("Gateway", n.gateway ?? "—")
            InfoRow("Internet", yesNo(n.internetReachable), tint: n.internetReachable == false ? .red : nil)
            InfoRow("DNS", yesNo(n.dnsWorking), tint: n.dnsWorking == false ? .red : nil)
            InfoRow("Last checked", dateText(n.lastCheckedAt))
        }
    }

    private func systemCard(_ s: StatusSnapshot) -> some View {
        let sys = s.system
        return Card(title: "System", symbol: "desktopcomputer") {
            InfoRow("Model", sys.model)
            InfoRow("macOS", sys.osVersion)
            InfoRow("Uptime", sys.bootTime.map { Formatting.duration(Date().timeIntervalSince($0)) } ?? "—")
            InfoRow("CPU", Formatting.percent(sys.cpuPercent))
            InfoRow("Memory", "\(Formatting.bytes(sys.memoryUsedBytes)) of \(Formatting.bytes(sys.memoryTotalBytes))\(sys.memoryPressure.map { " · \($0)" } ?? "")")
            InfoRow("Disk free", "\(Formatting.bytes(sys.diskFreeBytes)) of \(Formatting.bytes(sys.diskTotalBytes))")
            InfoRow("Thermal", sys.thermal.rawValue.capitalized, tint: sys.thermal >= .serious ? .orange : nil)
            InfoRow("External display", yesNo(sys.externalDisplayConnected))
            InfoRow("Agent overhead", "\(Formatting.percent(s.agent.cpuPercent)) CPU · \(Formatting.bytes(s.agent.residentBytes))")
        }
    }

    private func modeText(_ mode: EffectiveMode) -> String {
        switch mode {
        case .off: return "Off"
        case .fullAC: return "Always-On (AC)"
        case .fullBattery: return "Always-On (battery)"
        case .batterySaver: return "Battery Saver"
        case .relaxed: return "Relaxed — normal sleep allowed"
        }
    }

    private func availability(_ e: EndpointStatus) -> String {
        switch e.available {
        case true?: return "Available"
        case false?: return "Unavailable"
        case nil: return "Not checked"
        }
    }

    private func tint(_ e: EndpointStatus) -> Color? {
        e.available == true ? .green : (e.available == false ? .orange : nil)
    }
}
#endif
