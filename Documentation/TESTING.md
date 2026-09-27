# Testing

## Automated

```bash
swift test          # macOS and Linux
```

CI (`.github/workflows/ci.yml`) runs on every push:

* **macOS 14 (Apple Silicon runner):** builds every target with `-warnings-as-errors`, runs the
  test suite, assembles and code-signs `MacAlwaysOn.app`, smoke-runs both binaries, and
  `plutil -lint`s the launchd plists.
* **Linux (swift:6.1):** builds and tests the platform-neutral `AlwaysOnCore`.

| Suite | Covers |
|---|---|
| `PowerPolicyTests` (14) | AC / battery decisions, all four battery modes, hysteresis, latch-until-AC, lid override gating (helper, battery opt-in, floor, unknown %, thermal), critical / serious thermal, CPU guard. |
| `BackoffTests`, `ServiceRuntimeTests` | Exponential growth and cap, jitter bounds, overflow safety, crash → restart → give-up, stability reset, restart policies, requested stop ≠ crash, suspension, manual start clears failure. |
| `ServiceSupervisorTests` (9) | **Real child processes:** launch/running, crash loop to Failed, policy suspend/resume, manual stop suppresses restart, restart gets a new PID, network gate, invalid path, stdout captured to the rotated log, removal stops the service. |
| `HelperEngineTests` (13) | Simulated `pmset` / `pfctl`: apply / revert, lease expiry, renewal without re-running pmset, battery floor enforced by the helper, never reverting an administrator's own setting, pmset failure, invalid requests, full pf lifecycle (reload of the unmodified `pf.conf`, token, idempotence, `-X` release), reboot recovery, revert-all, release on helper stop, UID allow-list parsing, HTML escaping. |
| `TailscaleMonitorTests`, `TailscaleParserTests` | Connected / Stopped (with and without auto-reconnect) / NeedsLogin (never `up`) / unresponsive (app relaunch) / not installed. Real-world `status --json` shapes. |
| `DiagnosticsTests` | Healthy baseline, lid explanation, `SleepDisabled`, Tailscale down → "Remote access unavailable because …", sleep interval reporting, exposed listeners vs pf, failed services, staleness, snapshot codable round trip. |
| `UnixSocketTests` | Framed round trip, 0600 socket mode, **unauthorized peer rejected**, refusal to replace a non-socket file, typed agent protocol. |
| `NetworkProbeTests` | HTTP server bound to a specific address: routes, headers, 405 for non-GET, 403 when unauthorized, **refuses 0.0.0.0**. TCP refused / invalid, DNS. |
| `RedactorTests`, `RotatingFileWriterTests`, `ConfigStoreTests`, `IPAddressTests`, `SystemParserTests` | Secret redaction, rotation and 0600/0700 modes, defaults for missing keys, corrupt-file recovery, clamping, CIDR math, pmset / netstat / route / pfctl parsing. |

Code that needs real hardware (IOKit power, sleep/wake, NSWorkspace, NWPathMonitor) is
compiled in CI on macOS. Its behaviour is covered by the manual matrix below.

## Manual test matrix

Prepare: Tailscale signed in; Remote Login + Screen Sharing on; one command service
(`/bin/sh -c 'python3 -m http.server 8000'`, health port 8000) and one `.app` service.
Keep a second tailnet device (phone or laptop) for remote checks.
Observe with: `alwaysond --status`, `pmset -g assertions`, `pmset -g | grep SleepDisabled`, `tail -f ~/Library/Logs/MacAlwaysOn/agent.log`.

### AC power

| # | Steps | Expected |
|---|---|---|
| A1 | Lid open, AC, idle 30 min | Mac stays awake. `PreventUserIdleSystemSleep` and `PreventSystemSleep` named "MacAlwaysOn" appear in `pmset -g assertions`. SSH / VNC / web work from the tailnet. |
| A2 | Lid closed, AC, external display + keyboard | Stays awake (closed-display mode). Diagnostics "lid closed: Yes". |
| A3 | Lid closed, AC, no display, **no helper** | Mac **sleeps**. After opening: Diagnostics shows the sleep interval and "remote access was unavailable … system sleep". The dashboard never showed "running" during the gap. |
| A4 | Lid closed, AC, no display, helper + "Lid closed" on | Stays awake; `SleepDisabled 1`. Remote access keeps working. |
| A5 | Remote checks in A1/A4 | `ssh user@host.ts.net`, `open vnc://host.ts.net` and `curl http://host.ts.net:8686/api/status` succeed. `curl http://<LAN-IP>:8686` fails (not bound). |
| A6 | Service running | CPU / RAM / PID / last launch shown. Health check passes. |

### Battery

| # | Steps | Expected |
|---|---|---|
| B1 | Unplug, lid open, mode "Disable below 30 %" | Mode `fullBattery`. Idle assertion held; no system-sleep assertion. |
| B2 | Lid closed on battery, helper on, "Also on battery" **off** | Helper reverts `disablesleep` immediately. Mac sleeps. |
| B3 | Same with "Also on battery" on, floor 25 % | Stays awake. At ≤ 25 % the helper reverts (see `helper.log`) even if the agent is killed first (`kill -STOP` the agent: the lease expires within 10 min). |
| B4 | Discharge below 30 % | Mode `relaxed`. Assertions released. Non-essential services **Suspended**. Essential ones keep running. Mac may idle-sleep. |
| B5 | Charge to 34 %, then 35 % | Stays relaxed at 34 %. Re-arms at 35 % (hysteresis 5). |
| B6 | Mode "Disable at threshold" | After reaching the threshold, it stays off even if the % rises, until AC is connected. |
| B7 | Battery Saver | Only essential services run. No lid override. Networking alive. |

### Recovery

| # | Steps | Expected |
|---|---|---|
| R1 | Reboot (FileVault on) | After login: agent up, Tailscale connects, services start, dashboard healthy. With the helper: pf anchor re-applied, stale lease reverted. |
| R2 | Turn Wi-Fi off 1 min, then on | "Network lost" / "Network available" logged. Services with *wait for network* hold, then start. Tailscale re-checked immediately. |
| R3 | `tailscale down` (auto-reconnect on) | Within the backoff window `tailscale up` runs; logged as a recovery action. |
| R4 | Quit the Tailscale app (GUI variant) | Relaunched in the background. |
| R5 | Tailscale logged out | Diagnostics: NeedsLogin, "cannot be fixed automatically". No `up` loop. |
| R6 | `kill -9` a command service | Crashed → Restarting (backoff 2 s, 4 s, …) → Running. After more than 10 crashes in 10 min: Failed. |
| R7 | Quit a supervised `.app` | Restarted when the policy is *Always*. The stop button quits it without a restart. |
| R8 | `kill -9 $(pgrep alwaysond)` | launchd restarts the agent in ≤ 10 s. The orphaned command service is terminated and relaunched once. The `.app` is adopted, not duplicated. |
| R9 | Apple menu → Sleep, then wake | Sleep and wake times recorded; everything re-checked on wake. |
| R10 | Plug / unplug AC repeatedly | Mode follows within a second (event-driven). No assertion leak (`pmset -g assertions` shows one of each at most). |
| R11 | Change settings in the app | Agent reloads without a restart. Services reconcile. |

### Security

| # | Steps | Expected |
|---|---|---|
| S1 | `Scripts/security-audit.sh` | No MacAlwaysOn listener on `*`. The dashboard is on the Tailscale IP only. |
| S2 | Enable "Restrict ports to Tailscale" | `sudo pfctl -a com.apple/250.MacAlwaysOn -s rules` shows pass-from-tailnet then block. From a LAN device `nc -vz <LAN-IP> 22` fails; over Tailscale it works. |
| S3 | From outside (mobile data, Tailscale off): `nc -vz <public-IP> 22 / 5900 / 8686` | All fail. |
| S4 | As another local user: connect to the helper socket | Connection closed without a response (UID not authorized). |
| S5 | Dashboard allow-list set to another login | You get 403, and a denial is logged. |
| S6 | `grep -E 'tskey|password=' ~/Library/Logs/MacAlwaysOn/*.log` | Nothing, or only `[REDACTED]`. |
| S7 | `Scripts/uninstall.sh` | `pmset -g` has no `SleepDisabled 1`; pf anchor gone; no plists or binaries left; Tailscale untouched. |

### Resource use

| # | Steps | Expected |
|---|---|---|
| P1 | Idle 1 h, `top -pid $(pgrep alwaysond)` | Average CPU < 1 %. RSS roughly 20–40 MB. |
| P2 | Check the log size after a day | Rotated at 2 MiB × 5. |
