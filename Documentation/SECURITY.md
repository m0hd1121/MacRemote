# Security

Priority order: **Security > macOS compatibility > reliability > battery safety > performance > convenience.**

## Threat model

| Adversary | Goal | Controls |
|---|---|---|
| Internet attacker | Reach SSH / VNC / dashboard | Nothing is exposed publicly. The code contains no port forwarding, UPnP or NAT-PMP. The only listener we create binds to the Tailscale IPv4 (never `0.0.0.0`), and the server refuses a wildcard bind. Remote traffic arrives through Tailscale (WireGuard, identity-based ACLs). |
| Device on the same LAN | Reach SSH / VNC (Apple's daemons listen on all interfaces) | Optional pf anchor `com.apple/250.MacAlwaysOn` allows the chosen ports only from `100.64.0.0/10`, `fd7a:115c:a1e0::/48` and loopback. Diagnostics and `Scripts/security-audit.sh` flag LAN-reachable listeners. |
| Another tailnet device | Read the dashboard | Read-only (GET/HEAD only, no actions), with an optional allow-list of Tailscale login names checked with `tailscale whois`. Use Tailscale ACLs as the primary control. |
| Other local user | Control the agent, or escalate through the helper | The agent socket is in a 0700 directory, is 0600, and checks that the peer UID equals the owner. The helper serves only UIDs in a **root-owned** allow-list, which it refuses if group- or world-writable (checked with `getpeereid`). |
| Local malware as your user | Abuse the helper | The helper does only 3 fixed operations with validated arguments (ports 1–65535, ≤ 16 each; floor 10–90 %; lease 120–3600 s). It runs no client-supplied command or path. The worst case is keeping the Mac awake (bounded by lease, battery floor and thermal limit) or restricting, never opening, ports. |
| Tampering with root code | Replace the helper binary | The helper is copied to root-owned `/Library/PrivilegedHelperTools`. It is never executed from the user-writable app bundle. |
| Log exfiltration | Harvest secrets from logs | Every log line is redacted: `tskey-…`, Tailscale login URLs, bearer and basic tokens, `password=`, `token=`, `api_key=` and similar, URL credentials, and PEM private keys. Service environments are never logged. |

## Controls in detail

### Network
* **No public inbound ports.** The web dashboard binds `<tailscale-ip>:8686` only. It stops when
  Tailscale disconnects and re-binds when the IP changes.
* The dashboard also rejects any peer outside `100.64.0.0/10`, even though it binds only there.
* Response headers: `Content-Security-Policy: default-src 'none'`, `X-Frame-Options: DENY`,
  `nosniff`, `no-store`. Page content is HTML-escaped.
* We never listen on `0.0.0.0`. `StatusHTTPServer.start()` throws on a wildcard address.

### Authentication
* SSH and Screen Sharing use **macOS authentication** (Apple's own daemons).
* Tailscale identity guards network access, and optionally the dashboard via `whois`.
* There is no custom password system, so no passwords are stored.

### Privileges
| Component | Runs as | Why |
|---|---|---|
| MacAlwaysOn.app | user | UI only |
| alwaysond | user (LaunchAgent) | Assertions, IOKit reads, NSWorkspace and the Tailscale CLI need no root. |
| alwaysonhelper | root (optional) | `pmset -a disablesleep` and `pfctl` need root. |

The helper:
* never reverts a `SleepDisabled` setting that it did not apply itself;
* withdraws the override when the lease expires, at the battery floor, at serious thermal state
  on battery, at critical thermal state, when disabled, and when it is itself stopped;
* does not edit `/etc/pf.conf`. The anchor is loaded at runtime and removed on disable or
  uninstall. If the system ruleset lacks the `com.apple/*` anchor, the helper reloads the
  unmodified `/etc/pf.conf`, and refuses to proceed if that still does not help;
* holds a pf enable reference (`pfctl -E` token) and releases it (`pfctl -X`), so it never
  turns pf off for other users of pf.

### Secrets
* The design stores **no secrets**, so there are no Keychain items.
* `config.json` is 0600 in a 0700 directory. Service environment variables live there. The UI
  recommends that services read real secrets from the Keychain themselves.
* `tailscale up` is run with no arguments, so auth keys are never passed or stored.

### No weakening of macOS security
No SIP, Gatekeeper or FileVault changes. No kernel extensions. No modified system files. No
TCC bypasses. Every external command runs with an explicit argv through `ShellRunner`. There
is no API that takes a shell string.

## Verifying

```bash
Scripts/security-audit.sh          # listeners, dashboard binding, firewall, Tailscale
sudo Scripts/security-audit.sh     # + pf anchor contents
alwaysond --diagnose               # Security section
```

From a device **outside** your network and **not** on Tailscale, `nc -vz <public-ip> 22`,
`5900` and `8686` must all fail. From a tailnet device, they succeed when those services are on.

## Reporting

Please open a private security advisory on the repository rather than a public issue.
