# Troubleshooting

Start with **Diagnostics** in the app, or `alwaysond --diagnose`. Every failing check explains why it failed.

## The Mac slept with the lid closed

This is expected unless one of these holds:

1. **AC + external display** (plus a keyboard or mouse on some models): Apple's closed-display mode.
2. **Helper installed** and *Settings → Lid closed → Keep running with the lid closed* turned on.
   On battery, "Also on battery" must be on too, and the battery must be above the helper floor.

Check the current state:

```bash
pmset -g | grep -i sleepdisabled          # 1 = lid close will not sleep the Mac
ioreg -r -k AppleClamshellCausesSleep | grep -E 'AppleClamshell(State|CausesSleep)'
pmset -g assertions | grep -i macalwayson
```

The helper withdraws the override when Always-On relaxes, at the battery floor, at
serious/critical thermal state, when the agent stops renewing its 10-minute lease, and when
the helper itself stops. `helper.log` records the reason:
`sudo tail /Library/Logs/MacAlwaysOn/helper.log`.

## The dashboard says "Agent not running"

```bash
launchctl print gui/$(id -u)/com.macalwayson.agent | head -30
launchctl kickstart -k gui/$(id -u)/com.macalwayson.agent
cat /tmp/com.macalwayson.agent.stderr.log
tail -50 ~/Library/Logs/MacAlwaysOn/agent.log
```

If the plist is missing, run `Scripts/install.sh --skip-build` again.

## Tailscale shows as disconnected

| Diagnostic text | Meaning / fix |
|---|---|
| *not installed* | Install Tailscale from tailscale.com/download/mac. |
| *NeedsLogin* | The key expired or you were logged out. Open the Tailscale app and sign in. This cannot be automated. |
| *NeedsMachineAuth* | Approve the device in the Tailscale admin console. |
| *Stopped* | Tailscale was switched off. With auto-reconnect on, the agent runs `tailscale up`. Otherwise turn it on in the menu bar. |
| *not responding* | The Tailscale app or daemon is not running. The agent relaunches the GUI app (with auto-reconnect on). For `tailscaled`: `sudo launchctl kickstart -k system/com.tailscale.tailscaled`. |

After a reboot with the App Store or Standalone variant, Tailscale connects only after login.

## SSH / Screen Sharing "unavailable"

* *"nothing is listening on port 22/5900"*: turn on Remote Login or Screen Sharing in System Settings → General → Sharing.
* *"did not answer (filtered)"*: a firewall is dropping the traffic. If you enabled the pf anchor,
  Tailscale sources are allowed. Check the anchor with `sudo pfctl -a com.apple/250.MacAlwaysOn -s rules`.
* It works on the Mac itself but not remotely: check your Tailscale ACLs.

## The web dashboard is not reachable

It listens only on the Tailscale IP, so `http://localhost:8686` intentionally fails. Use
`http://<name>.ts.net:8686/` from a tailnet device. If the allow-list is set, your login must be
on it. Denials are logged as `Denied web dashboard access to …`.

## A service keeps restarting or shows "Failed"

* Read its output in `~/Library/Logs/MacAlwaysOn/services/<id>.log`.
* **Failed** means it crashed more than *N* times within the window (default 10 in 10 min).
  Fix the cause, then press **Start**.
* **Suspended** means the power policy stopped it (battery / thermal / CPU). It resumes by itself.
  Mark the service *Essential* to keep it running in Battery Saver.
* **Waiting for network** means "Wait for network" is on and no network path is available.
* Command services get launchd's minimal environment plus the PATH from the agent plist. Set
  anything else in the service's Environment field.

## macOS asks about "Local Network" access (macOS 15+)

The agent's probes can trigger this prompt. Allowing it lets local-network checks work.
Tailscale connectivity does not depend on it.

## Always-On keeps switching modes on battery

Raise **Re-arm after recovering N points** (hysteresis), or choose *Disable when threshold reached*,
which stays off until AC returns.

## Restoring normal sleep by hand

```bash
sudo /Library/PrivilegedHelperTools/com.macalwayson.helper --revert-all
sudo pmset -a disablesleep 0      # only if you set it yourself
```

## Collecting a support bundle

```bash
alwaysond --status --json > status.json
alwaysond --diagnose --json > diagnostics.json
cp ~/Library/Logs/MacAlwaysOn/agent.log .
pmset -g; pmset -g assertions
```

The logs are already redacted.
