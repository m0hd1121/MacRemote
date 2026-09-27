# Technical Feasibility — Always-On macOS over Tailscale

This document records what macOS actually allows. The implementation follows it.
Wherever this document says **Not Supported**, the application does not attempt
a workaround. It detects the condition and explains it.

Target: macOS 13 Ventura or later, Apple Silicon (arm64) first. Intel (x86_64)
is built as part of a Universal binary because no code path depends on the
architecture.

> **How to read the confidence notes.** Behaviour marked *verify on hardware*
> depends on the Mac model and macOS release and was not measured on a real
> Mac while this project was written (the development container is Linux). The
> Diagnostics page measures these on the actual machine at run time. It does
> not assume them.

---

## 1. The macOS power model, briefly

| Concept | What it is | Who controls it |
|---|---|---|
| **Display sleep** | Panel off, system fully running. | `kIOPMAssertionTypePreventUserIdleDisplaySleep`, `pmset displaysleep` |
| **System idle sleep** | Sleep after N minutes of no user input. | `kIOPMAssertionTypePreventUserIdleSystemSleep` (any user process, AC and battery) |
| **Forced sleep** | Apple menu → Sleep, low-battery sleep, lid close, thermal emergency. | Not overridable by power assertions. |
| **Lid-closed (clamshell) sleep** | The lid closing is a *forced* sleep trigger, unless the Mac is in supported clamshell mode. | IOPMrootDomain; state readable as `AppleClamshellState` / `AppleClamshellCausesSleep` |
| **Safe sleep / hibernation** | RAM written to disk after long sleep or low battery (`hibernatemode`, `standbydelay`). | `pmset`. Only happens *after* sleep, so it does not matter while the Mac stays awake. |
| **Power Nap / DarkWake** | Brief, OS-scheduled wakes for Apple services (Mail, iCloud, Time Machine). | The OS. Third-party apps cannot schedule their own work into DarkWake. |
| **Wake on network (`womp`)** | Wake on a Wi-Fi/Ethernet "magic packet", usually via a Bonjour Sleep Proxy on the LAN. | `pmset womp`, LAN infrastructure |

The important distinction: **power assertions prevent *idle* sleep. They do not
prevent *forced* sleep, and lid-close is a forced sleep trigger.** `caffeinate`,
`IOPMAssertionCreateWithName` and `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`
all keep a Mac awake with the lid open. None of them keep it awake when the lid
closes without an external display.

---

## 2. Feasibility matrix

### 2.1 Staying awake

| Requirement | Classification | Mechanism / reason |
|---|---|---|
| Prevent idle sleep, lid open, AC | **Fully Supported** | `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` from the user LaunchAgent. No privileges needed. |
| Prevent idle sleep, lid open, battery | **Fully Supported** | Same assertion. It is honoured on battery. |
| `kIOPMAssertionTypePreventSystemSleep` | **Supported With Conditions** | Honoured **on AC only**. The OS ignores it on battery. We take it on AC as a secondary guard and report whether it is active. |
| Lid closed, AC, external display + keyboard/mouse (Apple "closed-display mode") | **Fully Supported** | Official Apple feature. The idle assertion keeps it awake. |
| Lid closed, AC, **no** external display | **Supported With Conditions** | Only the root setting `pmset -a disablesleep 1` (shown as `SleepDisabled` in `pmset -g`) stops lid-close sleep. `pmset` is Apple's own tool, and using it needs no SIP change and no edits to system files. The flag is missing from the `pmset` man page, though, so Apple could change it. It needs the optional privileged helper and admin approval. *Verify on hardware.* The app confirms it by reading back `SleepDisabled`. |
| Lid closed, **battery** | **Supported With Conditions (opt-in, guarded)** | Same `disablesleep` mechanism. This carries a real **heat risk**, for example a closed Mac in a bag. So it is off by default. When turned on, it is fenced by: a battery floor that the root helper enforces on its own; thermal-state cut-off; a **lease** that expires if the agent stops renewing it. Leaving it permanently on is not supported. |
| Low-battery emergency sleep | **Not Supported (by design)** | macOS will sleep or shut down at critically low charge no matter what. We never try to stop that. Our floor is set well above it. |
| Thermal emergency sleep | **Not Supported (by design)** | macOS throttles and then sleeps at critical temperature. We cut Always-On earlier, at `serious`/`critical` thermal state, which is configurable. |
| Keep running *while asleep* | **Not Supported by macOS** | When the Mac is asleep, user processes, `tailscaled` and the network stack are frozen. Nothing we write can run then. |

### 2.2 Sleep detection and honesty

| Requirement | Classification | Mechanism |
|---|---|---|
| Detect imminent sleep / wake | **Fully Supported** | `IORegisterForSystemPower` (`kIOMessageSystemWillSleep`, `kIOMessageSystemHasPoweredOn`), and `NSWorkspace.willSleepNotification` / `didWakeNotification`. |
| Never claim "running" while asleep | **Fully Supported** | A sleeping agent cannot publish status. Every snapshot carries a timestamp. The GUI and the web page mark a snapshot **stale** past 2× the publish interval. The last sleep/wake times are recorded and shown. A Mac that is asleep is simply unreachable, and the Diagnostics text says so. |
| Lid state | **Supported With Conditions** | `AppleClamshellState` on `IOPMrootDomain` via IOKit, unprivileged. Present on laptops only. On desktops the value is missing and the UI shows "No lid". |
| Clamshell-causes-sleep | **Supported With Conditions** | `AppleClamshellCausesSleep` on the same registry entry. When `false`, the Mac is in closed-display mode or sleep has been disabled. |
| List active assertions | **Fully Supported** | `IOPMCopyAssertionsStatus` (aggregate), `pmset -g assertions` (detail). |

### 2.3 Power monitoring

| Requirement | Classification | Mechanism |
|---|---|---|
| AC / battery, %, charging | **Fully Supported** | `IOPSCopyPowerSourcesInfo`, `IOPSNotificationCreateRunLoopSource`. These are event-driven, not polled. |
| Battery health | **Supported With Conditions** | `kIOPSBatteryHealthKey` ("Good"/"Fair"/"Poor") where present. Cycle count and capacity come from `AppleSmartBattery` in IORegistry, where present. They are shown when available and marked "unavailable" otherwise. |
| Thermal state | **Fully Supported** | `ProcessInfo.thermalState` + `thermalStateDidChangeNotification`. |
| CPU load / memory pressure | **Fully Supported** | `host_statistics(HOST_CPU_LOAD_INFO)`, `host_statistics64(HOST_VM_INFO64)`, `DispatchSource.makeMemoryPressureSource`. |

### 2.4 Network and Tailscale

| Requirement | Classification | Mechanism |
|---|---|---|
| Network path change detection | **Fully Supported** | `NWPathMonitor` (Network.framework). Event-driven. |
| Internet / DNS checks | **Fully Supported** | `getaddrinfo` + a TCP connect with `NWConnection`. These run on path change and at a backed-off interval, not in a tight loop. |
| Detect Tailscale install | **Fully Supported** | The CLI in known locations: `/Applications/Tailscale.app/Contents/MacOS/Tailscale` (App Store & Standalone variants), `/usr/local/bin/tailscale`, `/opt/homebrew/bin/tailscale` (open-source `tailscaled`). |
| Status, IPs, hostname, MagicDNS name, peers | **Fully Supported** | `tailscale status --json` (official CLI, stable JSON). |
| Reachability self-test | **Fully Supported** | `tailscale ping` of a peer is optional. The local check is that `BackendState == "Running"` and that the node has a `100.x` address on a `utun` interface. |
| Auto-recover from transient disconnect | **Supported With Conditions** | Tailscale recovers from network changes by itself. We (a) relaunch the Tailscale GUI app if its process died (GUI variants), and (b) run `tailscale up` only when the backend is `Stopped` **and** the user turned on "auto-reconnect". `NeedsLogin` / expired keys **cannot** be fixed automatically. The user is told to re-authenticate. |
| Tailscale available **before login / after reboot** | **Supported With Conditions** | The **App Store and Standalone** variants run a Network Extension that starts with the user session. The **open-source `tailscaled`** runs as a LaunchDaemon and connects before any user logs in. For true headless 24/7 use, `tailscaled` is recommended. |
| Tailscale while the Mac sleeps | **Not Supported by macOS** | `tailscaled` is frozen with everything else. |
| Wake the Mac over Tailscale | **Not Supported** | A sleeping Mac's WireGuard endpoint is not running. Wake-on-LAN works only on the local network, through a Bonjour Sleep Proxy (Apple TV / HomePod), and never through Tailscale. |
| Tailscale SSH (`tailscale set --ssh`) | **Supported With Conditions** | Only the open-source `tailscaled` variant on macOS offers Tailscale SSH. With the GUI variants, use macOS Remote Login (sshd) reached over the tailnet. |

### 2.5 Remote access

| Requirement | Classification | Mechanism |
|---|---|---|
| Remote desktop | **Fully Supported** | Built-in **Screen Sharing** (VNC-compatible, port 5900, macOS-authenticated). Clients: Screen Sharing.app (`vnc://<tailscale-name>`), any VNC client. We do **not** add a third-party VNC server. |
| Remote shell | **Fully Supported** | Built-in **Remote Login** (sshd, port 22). |
| Bind Screen Sharing / sshd **only** to the Tailscale interface | **Not Supported by macOS** | Apple's sshd and screensharingd listen on all interfaces, and macOS gives no per-interface setting for them. |
| Restrict those ports to the tailnet | **Supported With Conditions** | The optional privileged helper loads a **pf anchor** under the existing `com.apple/*` anchor point. It does not edit `/etc/pf.conf`. The rules pass the configured ports only from `100.64.0.0/10` / `fd7a:115c:a1e0::/48` and loopback, and block them from everything else. This is removed on disable and on uninstall. |
| Web dashboard | **Fully Supported** | The agent's read-only status page binds **only to the Tailscale IPv4 address** (`NWListener` + `requiredLocalEndpoint`). It never binds to `0.0.0.0`. It re-binds when the Tailscale IP changes and shuts down when Tailscale is down. |
| Enable Screen Sharing / Remote Login programmatically | **Not Supported (without MDM)** | Since macOS 12.1, apps cannot turn these on silently. The user turns them on in *System Settings → General → Sharing*. We detect them with a local port probe and link to the pane. |
| No public exposure | **Fully Supported** | We never touch UPnP/NAT-PMP or router settings. We never listen on `0.0.0.0` ourselves. The security self-test lists every TCP listener (`lsof -iTCP -sTCP:LISTEN`) and flags any that listen on a non-loopback, non-Tailscale address. |

### 2.6 Process supervision and startup

| Requirement | Classification | Mechanism |
|---|---|---|
| Start at login, restart on crash | **Fully Supported** | Agent is a LaunchAgent (`RunAtLoad`, `KeepAlive`) limited to the `Aqua` session, because it launches GUI apps. |
| Supervise CLI programs | **Fully Supported** | `Foundation.Process`, with the exit status and termination reason (signal = crash). |
| Supervise `.app` bundles | **Fully Supported** | `NSWorkspace.openApplication` → `NSRunningApplication`, with KVO on `isTerminated`. Crash vs. normal quit comes from the unified log only, which we do not parse, so an unexpected quit counts as a crash when "restart on exit" is set. |
| Per-process CPU / RAM | **Fully Supported** | `proc_pid_rusage(RUSAGE_INFO_V4)` for the owned PIDs. Unprivileged for the user's own processes. |
| Run without any user logged in | **Supported With Conditions** | The LaunchAgent (and GUI apps) need a logged-in user. After a reboot with **FileVault on**, someone has to unlock the disk at the login window. Automatic login is disabled with FileVault. This is a deliberate Apple security property, and we do **not** ask users to turn off FileVault. CLI-only services could run from a LaunchDaemon. We deliberately keep them in the user context, for least privilege. |
| Auto power-on after power loss | **Fully Supported** | `pmset -a autorestart 1` (documented). Shown in Diagnostics as a recommendation. It is not changed silently. |

### 2.7 Privileges and security

| Requirement | Classification | Mechanism |
|---|---|---|
| No SIP / Gatekeeper / FileVault changes | **Fully Supported** | Nothing in this project requires them. |
| No kernel extensions | **Fully Supported** | None used. |
| Least privilege | **Fully Supported** | GUI + agent run as the user. Only the **optional** helper (lid-closed override, pf anchor) runs as root. It takes a fixed, validated command set over a Unix socket and checks the peer's UID with `getpeereid`. |
| Helper registration | **Supported With Conditions** | `SMAppService.daemon` (macOS 13+) needs a signed app. For unsigned local builds the installer script copies the helper into `/Library/PrivilegedHelperTools` (root-owned) and bootstraps it with `launchctl`, after asking for `sudo` once. |
| Secrets | **Fully Supported** | The design stores **no secrets**. Tailscale identity authenticates peers, and macOS accounts authenticate SSH and Screen Sharing. No password system of our own is needed, so no Keychain items are created. |

---

## 3. What this means in practice

| Scenario | Mac stays reachable over Tailscale? |
|---|---|
| Lid open, AC | **Yes.** No admin rights needed. |
| Lid open, battery | **Yes**, until the configured battery threshold. Then the policy relaxes and the Mac may idle-sleep normally. |
| Lid closed, AC, external display (closed-display mode) | **Yes.** No admin rights needed. |
| Lid closed, AC, no display | **Only** with the helper installed and "Lid-closed operation" on (`disablesleep`). Otherwise macOS sleeps, and the dashboard says so after wake. |
| Lid closed, battery | **Only** with the helper, "Lid-closed operation" on, **and** "Allow on battery" on. It is cut automatically at the battery floor / thermal limit / lease expiry. |
| Mac asleep for any reason | **No.** No software can change this. |
| After reboot, FileVault on | **No** until someone logs in at the Mac. Tailscale's open-source `tailscaled` can be reachable before login, but the agent and GUI apps start only after login. |

---

## 4. Rejected approaches

| Approach | Why rejected |
|---|---|
| Kernel extension / IOKit driver to swallow the clamshell event | Needs SIP changes / reduced security. It is also forbidden by the requirements. |
| Fake external display dongle / virtual display to trigger closed-display mode | A hardware or virtual-display trick, not a supported power behaviour. The project does not ship it. (Users who own a real display can use closed-display mode.) |
| Editing `/etc/pf.conf` | This is a system file. We use a runtime anchor under `com.apple/*` instead. |
| Our own VPN / tunnel | Forbidden. Tailscale is the only transport. |
| Exposing a management API on `0.0.0.0` | Forbidden. The web status page binds only to the Tailscale IP, and control stays on local Unix sockets. |
| Parsing the unified log to classify `.app` crashes | High CPU cost and fragile. We treat an unexpected exit as a crash instead. |
