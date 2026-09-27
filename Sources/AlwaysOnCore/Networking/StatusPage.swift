import Foundation

/// Renders the read-only web dashboard served on the Tailscale address. No scripts, no
/// forms, no external resources (the CSP forbids them).
public enum StatusPage {
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    public static func render(_ s: StatusSnapshot, viewer: String?, now: Date = Date()) -> String {
        func row(_ label: String, _ value: String) -> String {
            "<tr><th>\(escape(label))</th><td>\(escape(value))</td></tr>"
        }
        func yesNo(_ value: Bool?) -> String {
            switch value {
            case true?: return "yes"
            case false?: return "no"
            case nil: return "unknown"
            }
        }
        let levelClass: String
        switch s.overall.level {
        case .healthy: levelClass = "ok"
        case .degraded: levelClass = "warn"
        case .unhealthy: levelClass = "bad"
        }

        var power = row("Source", s.power.source.rawValue.uppercased())
        if let pct = s.power.batteryPercent { power += row("Battery", "\(pct)%\(s.power.isCharging == true ? " (charging)" : "")") }
        power += row("Lid", s.power.lid.rawValue)
        power += row("Always-On mode", s.power.policy.mode.rawValue)
        power += row("Idle sleep prevented", yesNo(s.power.assertions.idleSleepPrevented))
        power += row("System sleep disabled (lid-closed)", yesNo(s.power.systemSleepDisabled))
        if let last = s.power.lastWakeAt { power += row("Last wake", Formatting.time(last)) }

        var system = row("Model", s.system.model)
        system += row("OS", s.system.osVersion)
        if let boot = s.system.bootTime { system += row("Uptime", Formatting.duration(now.timeIntervalSince(boot))) }
        system += row("CPU", Formatting.percent(s.system.cpuPercent))
        system += row("Memory", "\(Formatting.bytes(s.system.memoryUsedBytes)) / \(Formatting.bytes(s.system.memoryTotalBytes))")
        system += row("Thermal", s.system.thermal.rawValue)

        var network = row("Connected", yesNo(s.network.pathSatisfied))
        network += row("Interfaces", s.network.interfaces.joined(separator: ", "))
        network += row("DNS", yesNo(s.network.dnsWorking))
        network += row("Internet", yesNo(s.network.internetReachable))
        network += row("Tailscale", s.tailscale.connected ? "connected as \(s.tailscale.dnsName ?? s.tailscale.hostName ?? "?")" : (s.tailscale.backendState ?? "not connected"))
        network += row("Tailscale IP", s.tailscale.ipv4 ?? "—")

        var remote = row("SSH", s.remoteAccess.ssh.detail)
        remote += row("Screen Sharing", s.remoteAccess.screenSharing.detail)
        remote += row("Tailnet-only firewall", yesNo(s.remoteAccess.firewallRestricted))

        var services = ""
        for svc in s.services {
            var detail = svc.state.rawValue
            if let pid = svc.pid { detail += " · pid \(pid)" }
            if let cpu = svc.cpuPercent { detail += " · CPU \(Formatting.percent(cpu))" }
            if let mem = svc.memoryBytes { detail += " · \(Formatting.bytes(mem))" }
            if svc.restartCount > 0 { detail += " · \(svc.restartCount) restarts" }
            services += row(svc.name, detail)
        }
        if services.isEmpty { services = row("—", "No services configured") }

        let summary = s.overall.summary.map { "<li>\(escape($0))</li>" }.joined()
        let viewerLine = viewer.map { "<p class=muted>Viewing as \(escape($0)) via Tailscale.</p>" } ?? ""

        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(s.tailscale.hostName ?? "Mac")) · MacAlwaysOn</title>
        <style>
        :root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--ok:#1a7f37;--warn:#9a6700;--bad:#cf222e}
        @media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--muted:#98989d;--line:#38383a;--ok:#3fb950;--warn:#d29922;--bad:#f85149}}
        body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,system-ui,sans-serif}
        main{max-width:760px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}h2{font-size:15px;margin:24px 0 6px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
        table{width:100%;border-collapse:collapse}th,td{padding:6px 0;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}th{width:40%;font-weight:500;color:var(--muted)}
        .ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.muted{color:var(--muted);font-size:13px}ul{margin:4px 0;padding-left:20px}
        </style></head><body><main>
        <h1>\(escape(s.tailscale.dnsName ?? s.system.model))</h1>
        <p class="\(levelClass)"><strong>\(escape(s.overall.level.rawValue.capitalized))</strong></p><ul>\(summary)</ul>
        <p class=muted>Snapshot \(escape(Formatting.time(s.generatedAt))) · read-only · refresh the page to update.</p>\(viewerLine)
        <h2>Power</h2><table>\(power)</table>
        <h2>Services</h2><table>\(services)</table>
        <h2>Network &amp; Tailscale</h2><table>\(network)</table>
        <h2>Remote access</h2><table>\(remote)</table>
        <h2>System</h2><table>\(system)</table>
        </main></body></html>
        """
    }
}
