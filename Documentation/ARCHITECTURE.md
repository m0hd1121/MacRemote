# Architecture

## 1. Components

```
┌──────────────────────────── user session (uid = you) ────────────────────────────┐
│                                                                                   │
│  MacAlwaysOn.app  (SwiftUI, menu bar + window)                                    │
│    • dashboard, services editor, diagnostics, logs, settings                      │
│    • never supervises anything itself; it is a client                             │
│          │  JSON over Unix socket  ~/Library/Application Support/MacAlwaysOn/     │
│          ▼                          agent.sock  (dir 0700, socket 0600)           │
│  alwaysond  (LaunchAgent com.macalwayson.agent, KeepAlive, Aqua session)          │
│    ├─ PowerMonitor      IOPS notifications, sleep/wake, clamshell, thermal        │
│    ├─ AssertionManager  IOPM assertions (idle-sleep, system-sleep on AC)          │
│    ├─ PolicyEngine      pure function: (power, config) → decision                 │
│    ├─ NetworkMonitor    NWPathMonitor + backed-off DNS/Internet probe             │
│    ├─ TailscaleMonitor  `tailscale status --json`, recovery with backoff          │
│    ├─ ServiceSupervisor Process / NSWorkspace, restart w/ exponential backoff     │
│    ├─ RemoteAccessProbe TCP probe of 22 / 5900 / 3283 on Tailscale IP             │
│    ├─ StatusWebServer   read-only HTTP bound ONLY to Tailscale IPv4               │
│    ├─ Diagnostics       explains failures in plain language                       │
│    └─ HelperClient      lease renewals to the root helper (if installed)          │
│          │  JSON over Unix socket /var/run/com.macalwayson.helper.sock            │
│          │  (peer uid verified with getpeereid against root-owned allow-list)     │
└──────────┼────────────────────────────────────────────────────────────────────────┘
           ▼
┌──────────────────────────── root (optional) ─────────────────────────────────────┐
│  com.macalwayson.helper  (LaunchDaemon, /Library/PrivilegedHelperTools)           │
│    • exactly three commands: status, setLidClosedOperation, setFirewall           │
│    • runs `pmset -a disablesleep 0|1` and `pfctl -a com.apple/250.MacAlwaysOn`    │
│    • independent safety loop: battery floor, thermal, lease expiry → revert       │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### Why this split

| Decision | Reason |
|---|---|
| Supervisor is a **LaunchAgent**, not a LaunchDaemon | It must launch and watch GUI apps (a trading app, for example) in the user's Aqua session. It also needs no root for power assertions, IOKit reads, NWPathMonitor, or the Tailscale CLI. |
| The GUI is a pure client | Closing or crashing the window never affects supervision, and the GUI is not needed for 24/7 operation. |
| The root helper is optional and tiny | Only two operations need root: `pmset disablesleep` and loading a pf anchor. Everything else works without it. Its command set is fixed. It runs no arbitrary shell, and it validates every argument. |
| The helper enforces safety on its own | If the agent crashes, is uninstalled, or the GUI is killed, a root setting such as `disablesleep 1` must not be left behind. The helper reverts it when the **lease** expires (default 10 min, renewed every 2 min), and also below the battery floor and at critical thermal state. |
| JSON over Unix sockets, not XPC | The same protocol works for the SwiftUI app, the agent, the helper, and the unit tests on Linux CI. Filesystem permissions (0700 dir) protect the agent socket. `getpeereid` + a root-owned UID allow-list protects the helper socket. |
| `AlwaysOnCore` is platform-neutral | Policy, backoff, supervision state machine, parsers, redaction, log rotation, IPC framing, and the supervisor for command-line services all compile and are unit-tested on Linux as well as macOS. |

## 2. Source layout

```
Package.swift                 SwiftPM manifest (library + 3 executables + tests)
project.yml                   XcodeGen spec → MacAlwaysOn.xcodeproj
Sources/
  AlwaysOnCore/               platform-neutral (Foundation only)
    Models/                   Configuration, ServiceSpec, StatusSnapshot, …
    Policy/                   PowerPolicy (pure decision function)
    Supervision/              Backoff, ServiceRuntime state machine, CommandSupervisor
    Parsing/                  Tailscale JSON, pmset, ioreg, lsof parsers
    Diagnostics/              DiagnosticCheck model + DiagnosticsEngine (explanations)
    Logging/                  Redactor, RotatingFileWriter, EventLogger
    IPC/                      framed JSON, UnixSocket server/client, agent & helper protocols
    Persistence/              ConfigStore (atomic, 0600), Paths
    Utilities/                ShellRunner (argv only, never /bin/sh -c), Clock
  AlwaysOnPlatform/           macOS only (IOKit, Network, AppKit); compiled out elsewhere
    Power/                    PowerSourceReader/Monitor, SleepWakeMonitor, AssertionManager, Clamshell
    Network/                  NetworkMonitor, ConnectivityProbe
    Tailscale/                TailscaleCLI, TailscaleMonitor
    Process/                  AppSupervisor (NSWorkspace), ProcessMetrics (proc_pid_rusage)
    System/                   SystemInfo (model, OS, uptime, CPU, RAM, disk)
    RemoteAccess/             PortProbe, StatusWebServer (NWListener)
    Helper/                   HelperClient
  alwaysond/                  LaunchAgent entry point + AgentController (glue)
  alwaysonhelper/             LaunchDaemon entry point + HelperController
  MacAlwaysOn/                SwiftUI app
Tests/AlwaysOnCoreTests/      XCTest (runs on macOS and Linux)
Resources/LaunchAgents/       com.macalwayson.agent.plist (template)
Resources/LaunchDaemons/      com.macalwayson.helper.plist
Scripts/                      build-app.sh, install.sh, uninstall.sh, security-audit.sh
Documentation/
```

## 3. Communication

### 3.1 App ↔ Agent (`agent.sock`)

Frames are length-prefixed: a 4-byte big-endian length, then a UTF-8 JSON body,
up to 4 MiB. One request and one response per connection.

| Request | Effect |
|---|---|
| `status` | Returns the full `StatusSnapshot`. |
| `reloadConfig` | Agent re-reads `config.json` (the app has written it atomically). |
| `startService(id)` / `stopService(id)` / `restartService(id)` | Supervisor action. A manual stop suspends auto-restart until the next start. |
| `runDiagnostics` | Runs all checks now and returns the report. |
| `recentLogs(limit)` | Tail of the redacted event log. |

### 3.2 Agent ↔ Helper (`/var/run/com.macalwayson.helper.sock`)

| Request | Validation | Effect |
|---|---|---|
| `status` | — | `SleepDisabled` read back from `pmset -g`, firewall state, lease expiry, last revert reason. |
| `setLidClosedOperation {enabled, allowOnBattery, batteryFloorPercent, leaseSeconds}` | floor 10…90, lease 120…3600 | `pmset -a disablesleep 1` / `0`. Stores the lease. |
| `setFirewall {enabled, tcpPorts, udpPorts}` | ≤ 16 ports each, 1…65535 | Loads / flushes the pf anchor `com.apple/250.MacAlwaysOn`. Holds / releases a `pfctl -E` reference token. |

The helper serves a connection only when `getpeereid()` returns a UID listed in
`/Library/Application Support/MacAlwaysOn/helper-authorized-uids`, which is
root-owned, mode 0644, and written by the installer.

## 4. Power policy

`PowerPolicy.evaluate(power:thermal:config:lidClosedCapable:) → PolicyDecision` is a pure
function and is unit-tested.

| Input | Outcome |
|---|---|
| Always-On disabled | No assertions. Services run per their own settings. Lid override off. |
| AC | Idle-sleep assertion + system-sleep assertion. Lid override if enabled. All services. |
| Battery, mode **Always On** | Idle-sleep assertion. Lid override only if `allowOnBattery`. All services. Below the battery floor, **Battery Saver** takes over. |
| Battery, mode **Battery Saver** | No lid override. Only `essential` services. Display sleep allowed. The idle-sleep assertion is kept unless below the floor. |
| Battery, mode **Disable below X%** | Like Always On above X%. At or below X%: no assertions, non-essential services stopped, normal sleep. |
| Battery, mode **Disable at X%** | Like Always On until X% is reached once. Always-On then latches off until AC returns. |
| Thermal `serious` | Stop `intensive` services. Lid override is withdrawn on battery. |
| Thermal `critical` | Everything relaxes (no assertions, no lid override). Only essential services run. |
| CPU guard | If system CPU > `maxCPUPercent` for 3 consecutive samples on battery, `intensive` services are stopped. |

Hysteresis: after a threshold trips, the policy requires the battery to climb
`hysteresisPercent` (default 5) above it before it re-enables anything. This
stops flapping at the boundary.

## 5. Startup sequence

1. macOS boots. `tailscaled` (open-source variant) starts as a LaunchDaemon if installed.
2. The helper LaunchDaemon starts (if installed), re-applies the persisted pf anchor, and checks the lease. A stale lease reverts `disablesleep`.
3. The user logs in (FileVault unlock if enabled). The Tailscale GUI variant starts as a login item.
4. launchd starts `alwaysond` (`RunAtLoad`).
5. Agent loads config, opens its control socket, starts the power, sleep/wake, and thermal monitors.
6. Policy is evaluated, assertions are taken, and the lid override is requested from the helper.
7. The network monitor waits for a satisfied path, then starts the Tailscale monitor (with backoff until `Running`).
8. The supervisor starts `launchAtStart` services in dependency-free order. Services that need the network start after the network is up.
9. Remote access is verified: Tailscale IP known, ports 22 / 5900 probed on it, and the web dashboard bound.
10. A snapshot is published, and the dashboard shows the aggregate health.

## 6. Recovery

| Event | Detection | Action |
|---|---|---|
| Reboot | launchd | Sequence above. |
| Agent crash | launchd `KeepAlive` | Restarted by launchd. Supervised CLI children are in the agent's process group and are reaped with it. `.app` services keep running and are **re-adopted** by bundle ID on start. The helper lease expires if the agent is not back within the lease window. |
| Service crash | `Process.terminationHandler` / KVO `isTerminated` | Logged. Restarted with backoff `min(base·2ⁿ, max)` ±20% jitter. The counter resets after `stableAfterSeconds` of uptime. After `maxRestartsInWindow`, the service goes to **Failed** and waits for manual action. |
| Tailscale down | status poll + path change | Backoff 5 s → 5 min. If the GUI app process is gone → `open -b io.tailscale.ipn.macsys` / `.macos`. If `Stopped` and auto-reconnect is on → `tailscale up`. If `NeedsLogin` → report only. |
| Network change / Wi-Fi reconnect / DNS failure | `NWPathMonitor` | Re-probe immediately, then back off. Nudge the Tailscale poll. |
| Sleep → wake | `kIOMessageSystemHasPoweredOn` | Record the sleep interval. Re-evaluate everything. Mark services whose PIDs vanished. Re-bind the web server. |
| Lid open / close | clamshell read on each power / sleep event plus a 30 s cheap read | Re-evaluate policy. |
| Power source / battery change | IOPS notification | Re-evaluate policy. Start or stop services per decision. |
| Config change | `reloadConfig` | Re-evaluate. Reconcile services (add / remove / update). |

## 7. Resource budget

* Event-driven for power, sleep, thermal, network path, and child exit.
* Periodic work: Tailscale status every 60 s when healthy (backoff when not); Internet/DNS probe every 5 min; process metrics every 15 s only for supervised PIDs; clamshell read every 30 s (one IORegistry property read); helper lease renewal every 120 s.
* Snapshot publication is on demand (socket request) plus the web page. Nothing is written to disk for status.
* Logs: JSON lines, rotated at 2 MiB × 5 files. Service stdout/err is rotated at 5 MiB when the service is launched.

The expected idle footprint is well under 1 % CPU and ~20–40 MB RSS for the agent.
Measure it on the machine with Activity Monitor or `ps -o rss,pcpu -p $(pgrep alwaysond)`.
The Diagnostics page shows the agent's own usage.

## 8. Security model (summary; details in SECURITY.md)

* No listener on `0.0.0.0`. The only TCP listener we create binds to the Tailscale IPv4. It is read-only, and it requires the peer to come from the tailnet range.
* No port forwarding, UPnP, or NAT-PMP anywhere in the code.
* No shell interpolation: every external command is run with an explicit argv (`ShellRunner`).
* No secrets stored. The redactor strips `tskey-…`, bearer tokens, `password=`, and private key blocks from every log line.
* The root helper has a fixed command set, validated inputs, a peer UID check, a root-owned binary location, and no network access.
