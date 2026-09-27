# MacAlwaysOn

Turns a MacBook into a personal server that stays reachable **only over Tailscale**. It keeps
the Mac awake when macOS allows it and supervises the apps and services you choose. It also
explains, plainly, when macOS will not allow it.

> **The honest summary.** Power assertions keep a Mac awake with the lid **open**, on AC or on
> battery. With the lid **closed**, a Mac stays awake only in Apple's closed-display mode (AC +
> external display), or when the optional root helper sets `pmset disablesleep` for you.
> Nothing can keep a *sleeping* Mac reachable. The app never claims otherwise. See
> [TECHNICAL_FEASIBILITY.md](Documentation/TECHNICAL_FEASIBILITY.md).

## What it does

| Area | Features |
|---|---|
| Always-On | Separate AC and battery modes. Battery modes: Always On, Battery Saver, Disable below X %, Disable at X %. Hysteresis. Thermal and CPU guards. Optional lid-closed operation through a leased, self-reverting root helper. |
| Supervision | Keeps `.app` bundles and command-line programs running. Crash detection, exponential backoff with jitter, a give-up window, CPU / RAM / PID / launch and crash times, restart counts, TCP health checks, per-service logs, network gating, and priority-based suspension on low battery. |
| Tailscale | Detects the variant (App Store, Standalone, open-source). Reports status, IP, MagicDNS name, tailnet and peers. Relaunches the app, and runs `tailscale up` only when the backend is Stopped. Never logs in for you and never stores keys. |
| Remote access | Checks Remote Login (SSH) and Screen Sharing on the Tailscale IP. Read-only web status page bound **only** to the Tailscale IPv4, with an optional per-user allow-list via `tailscale whois`. Optional pf anchor limits SSH / VNC to the tailnet. |
| Diagnostics | Power, network, Tailscale, remote access, services and exposure checks, each with a plain-language reason and a remedy. For example: *"Closing the lid will put the Mac to sleep …"* or *"Remote access unavailable because Tailscale is not connected …"*. |
| UI | SwiftUI dashboard, services editor, diagnostics, logs, settings, and a menu bar item. |
| CLI | `alwaysond --status`, `alwaysond --diagnose [--json]` |

## Components

```
MacAlwaysOn.app      SwiftUI client (optional at runtime)
alwaysond            LaunchAgent, runs as you: policy, assertions, supervision, monitoring
alwaysonhelper       OPTIONAL LaunchDaemon, runs as root: pmset disablesleep lease + pf anchor
```

## Quick start

```bash
git clone … && cd MacRemote
Scripts/install.sh                 # app + agent (no root)
Scripts/install.sh --with-helper   # + lid-closed operation / tailnet-only firewall (sudo)
```

Then install and sign in to [Tailscale](https://tailscale.com/download/mac). Turn on Remote Login
and/or Screen Sharing in *System Settings → General → Sharing*. Open **MacAlwaysOn → Diagnostics**.

From another device on your tailnet:

```bash
ssh you@your-mac.tailnet-name.ts.net
open vnc://your-mac.tailnet-name.ts.net
open http://your-mac.tailnet-name.ts.net:8686/
```

## Documentation

* [Documentation/INSTALLATION.md](Documentation/INSTALLATION.md): install, upgrade, uninstall
* [Documentation/TECHNICAL_FEASIBILITY.md](Documentation/TECHNICAL_FEASIBILITY.md): what macOS allows, requirement by requirement
* [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md): components, IPC, policy, startup, recovery
* [Documentation/SECURITY.md](Documentation/SECURITY.md): threat model and controls
* [Documentation/TROUBLESHOOTING.md](Documentation/TROUBLESHOOTING.md)
* [Documentation/TESTING.md](Documentation/TESTING.md): automated tests and the manual test matrix
* [Documentation/FINAL_REPORT.md](Documentation/FINAL_REPORT.md): what works where, limits, recommended 24/7 setup

## Building and testing

```bash
swift build                   # all targets (macOS); only AlwaysOnCore on Linux
swift test                    # 97 unit/integration tests (macOS and Linux)
Scripts/build-app.sh          # → build/MacAlwaysOn.app  (--universal for arm64 + x86_64)
xcodegen generate             # optional: MacAlwaysOn.xcodeproj from project.yml
```

Requirements: macOS 13+, Xcode 15+ / Swift 5.9+. Apple Silicon is native. Intel is supported
through a Universal build. There are no third-party dependencies.
