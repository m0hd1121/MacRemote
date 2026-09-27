#if os(macOS)
import AppKit
import SwiftUI
import AlwaysOnCore

struct RemoteAccessView: View {
    @EnvironmentObject private var store: AgentStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Remote access works only through your private Tailscale network. This app never opens router ports, never uses UPnP, and never listens on public interfaces.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let s = store.snapshot {
                    let host = s.remoteAccess.tailscaleHost ?? s.tailscale.dnsName
                    let ip = s.remoteAccess.tailscaleIP ?? s.tailscale.ipv4
                    Card(title: "This Mac on your tailnet", symbol: "point.3.connected.trianglepath.dotted") {
                        InfoRow("Tailscale", s.tailscale.connected ? "Connected" : "Not connected", tint: s.tailscale.connected ? .green : .red)
                        InfoRow("MagicDNS name", host ?? "—")
                        InfoRow("Tailscale IP", ip ?? "—")
                        if !s.tailscale.connected {
                            Text("Remote access is unavailable because Tailscale is not connected. \(s.tailscale.lastError ?? "")")
                                .foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    endpointCard(title: "SSH (Remote Login)", symbol: "terminal", endpoint: s.remoteAccess.ssh,
                                 command: host.map { "ssh \(NSUserName())@\($0)" },
                                 help: "Enable Remote Login in System Settings → General → Sharing. Authentication uses your macOS account (use SSH keys; consider disabling password login in /etc/ssh/sshd_config.d/).")

                    endpointCard(title: "Remote Desktop (Screen Sharing)", symbol: "display", endpoint: s.remoteAccess.screenSharing,
                                 command: host.map { "vnc://\($0)" },
                                 help: "Enable Screen Sharing in System Settings → General → Sharing. Connect from another Mac with Screen Sharing.app or Finder → Go → Connect to Server, or from any VNC client on your tailnet.")

                    endpointCard(title: "Web status dashboard (read-only)", symbol: "safari", endpoint: s.remoteAccess.webDashboard,
                                 command: host.map { "http://\($0):\(store.config.remoteAccess.webDashboardPort)/" },
                                 help: "Bound only to the Tailscale address. It shows status and cannot change anything. Restrict viewers in Settings → Remote access, and with Tailscale ACLs.")

                    Card(title: "Tailnet-only firewall (optional)", symbol: "shield.lefthalf.filled") {
                        Text("macOS offers no per-interface setting for sshd and Screen Sharing: they listen on every interface, so devices on your local network can reach them too. With the privileged helper installed, MacAlwaysOn can load a pf anchor that accepts these ports only from Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48) and loopback.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        InfoRow("Helper", s.helper.installed ? (s.helper.reachable ? "Installed" : "Installed, not reachable") : "Not installed")
                        InfoRow("Firewall anchor", s.remoteAccess.firewallRestricted == true ? "Active" : "Inactive")
                        Toggle("Restrict remote-access ports to Tailscale", isOn: Binding(
                            get: { store.config.remoteAccess.restrictPortsToTailnet },
                            set: { value in store.update { $0.remoteAccess.restrictPortsToTailnet = value } }
                        ))
                        .disabled(!s.helper.installed)
                    }
                }

                Button("Open Sharing Settings…") { store.openSharingSettings() }
            }
            .padding(20)
        }
    }

    private func endpointCard(title: String, symbol: String, endpoint: EndpointStatus, command: String?, help: String) -> some View {
        Card(title: title, symbol: symbol) {
            HStack {
                StateBadge(text: endpoint.available == true ? "Available" : (endpoint.available == false ? "Unavailable" : "Not checked"),
                           color: endpoint.available == true ? .green : (endpoint.available == false ? .orange : .secondary))
                Text(endpoint.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let command {
                HStack {
                    Text(command).font(.callout.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
            }
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
