# Final Report

## Verification status

* **Built and tested:** all five targets compile on a macOS 14 Apple Silicon CI runner with
  warnings treated as errors. 97 automated tests pass on macOS and Linux. The app bundle is
  assembled, signed, and verified with `codesign --verify`. Both binaries start (`--version`).
* **Not yet verified on physical hardware:** lid-close behaviour, battery transitions, sleep and
  wake, NSWorkspace supervision, and Tailscale end-to-end. These can only be checked on a real
  MacBook. The [manual test matrix](TESTING.md#manual-test-matrix) lists each check, and the
  Diagnostics page measures these conditions at run time instead of assuming them.

## What works while plugged in (AC)

* The idle-sleep and system-sleep assertions keep the Mac fully awake with the lid **open**.
* With the lid **closed**:
  * with an external display (Apple closed-display mode), it keeps running with no extra privileges;
  * with no display, it keeps running only with the optional helper (`pmset disablesleep`, leased and self-reverting).
* Networking, Tailscale, supervised apps and services, SSH, Screen Sharing and the web dashboard all keep running.

## What works on battery

* Lid open: the Mac stays awake through the idle-sleep assertion. macOS ignores system-sleep assertions on battery, so the app doesn't request one.
* The battery modes (Always On, Battery Saver, Disable below X %, Disable at X %) are configurable, with hysteresis.
* Below the threshold, non-essential services stop, assertions are released, and normal sleep resumes.
* Lid closed on battery works only as an explicit opt-in through the helper. The helper enforces its own battery floor and thermal limits, and a lease that expires if the agent stops renewing it.

## What works with the lid closed

| Condition | Result |
|---|---|
| AC + external display | Awake (Apple-supported) |
| AC, no display, helper on | Awake (`SleepDisabled = 1`) |
| Battery, helper on, battery opt-in, above floor, not hot | Awake |
| Any other combination | macOS sleeps. The app reports it after wake and never claims it was running. |

## What macOS prevents

* Any process running during sleep: `tailscaled` and all services are frozen.
* Waking a sleeping Mac through Tailscale. Wake-on-LAN works only on the local network via a Bonjour Sleep Proxy.
* Overriding low-battery or thermal emergency sleep.
* Binding Apple's sshd or Screen Sharing to a single interface (pf is the workaround).
* Turning on Remote Login or Screen Sharing programmatically without MDM.
* Unlocking FileVault automatically after a reboot. A person must log in, so GUI agents and apps start only after login.
* Keeping lid-closed operation running without root. Power assertions do not cover lid-close sleep.

## Permissions required

| Component | Privilege | Required? |
|---|---|---|
| App + agent | Your user account. No TCC permissions (a Local Network prompt may appear on macOS 15+). | Yes |
| Root helper | root LaunchDaemon, installed once with `sudo` | Only for lid-closed operation without a display, and for the tailnet-only pf firewall |
| Remote Login / Screen Sharing | Turned on by you in System Settings | For SSH / remote desktop |

## How remote access works

`client → Tailscale (WireGuard, identity + ACLs) → utun on the Mac → sshd :22 / screensharingd :5900 / MacAlwaysOn dashboard <ts-ip>:8686`.

Connect by MagicDNS name, for example `ssh me@mac.tailnet.ts.net` or `vnc://mac.tailnet.ts.net`, or by the 100.x IP.

## How Tailscale protects remote access

* No inbound ports are opened on the router. Tailscale uses outbound NAT traversal, falling back to DERP relays.
* End-to-end WireGuard encryption, with device identity tied to your identity provider.
* Tailnet ACLs decide which devices and users may reach which ports.
* MacAlwaysOn adds:
  * a dashboard bound only to the Tailscale IP, with an optional per-login allow-list;
  * an optional pf anchor that stops LAN devices from reaching SSH and VNC;
  * a security audit that flags listeners open to all interfaces.

## CPU / RAM overhead (design targets; measure with P1 in TESTING.md)

* Event-driven for power, sleep, thermal and network path changes.
* Timers run every 15 s (metrics), 60 s (Tailscale status and the remote-access probe), 120 s (helper lease renewal), and 300 s (DNS / Internet check, with backoff when failing).
* Expected: well under 1 % average CPU and about 20–40 MB RSS for the agent, and a few MB for the helper. The UI is not needed at runtime. The dashboard shows the agent's own CPU and memory use.

## Known limitations

* The lid-closed override relies on `pmset disablesleep`. It is Apple's tool but not documented in `man pmset`, so a future macOS could change it. The app confirms it works by reading back `SleepDisabled`.
* `.app` services expose no exit code, so any exit the agent did not request counts as a crash.
* Tailscale SSH is available only with the open-source `tailscaled`. The GUI variants use macOS Remote Login instead.
* The GUI variants of Tailscale connect only after login. Use `tailscaled` for access before login.
* The pf anchor depends on the stock `/etc/pf.conf` `com.apple/*` anchor point. The helper refuses to proceed if that anchor point is missing.
* The app does not inspect router settings. Check port forwarding and UPnP yourself (see SECURITY.md).
* Local builds are ad-hoc signed. Distributing to other Macs requires a Developer ID signature and notarization (`SIGN_IDENTITY=… Scripts/build-app.sh`).

## Recommended configuration for 24/7 operation

1. Keep the Mac on **AC power**, ideally with an external display attached (closed-display mode). Otherwise install the helper and enable lid-closed operation on AC only.
2. Run `sudo pmset -a autorestart 1`.
3. Use the open-source **`tailscaled`** for connectivity before login. Enable MagicDNS and write ACLs that allow only your devices to reach ports 22, 5900 and 8686.
4. Turn on Remote Login with SSH keys (disable password authentication) and Screen Sharing only if needed.
5. Install with `--with-helper` and enable **Restrict ports to Tailscale**.
6. Set battery mode to **Disable below threshold**, at 30 %, with lid-closed-on-battery **off**.
7. Mark critical services **Essential** and heavy ones **Intensive**, and set a health-check port where possible.
8. Run `alwaysond --diagnose` and `Scripts/security-audit.sh` after setup and after macOS updates.
