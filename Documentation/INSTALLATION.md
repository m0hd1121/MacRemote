# Installation

## Requirements

* macOS 13 Ventura or later (Apple Silicon or Intel)
* Xcode 15+ or the Command Line Tools with Swift 5.9+ (`xcode-select --install`)
* [Tailscale](https://tailscale.com/download/mac), installed and signed in by you. MacAlwaysOn never installs it.

## Install

```bash
Scripts/install.sh                 # standard install
Scripts/install.sh --with-helper   # also install the optional root helper
```

The installer:

1. Builds `build/MacAlwaysOn.app` (`Scripts/build-app.sh`, ad-hoc signed; set
   `SIGN_IDENTITY` to use your Developer ID).
2. Copies the app to `/Applications`, or to `~/Applications` if `/Applications` is not writable.
3. Writes `~/Library/LaunchAgents/com.macalwayson.agent.plist` and bootstraps it in your GUI
   session (`RunAtLoad`, `KeepAlive`). It starts at every login and restarts if it exits.
4. **Only with `--with-helper`**, asks for `sudo` once to:
   * copy the helper to `/Library/PrivilegedHelperTools/com.macalwayson.helper` (root:wheel 755)
   * install `/Library/LaunchDaemons/com.macalwayson.helper.plist`
   * write your UID to `/Library/Application Support/MacAlwaysOn/helper-authorized-uids` (root, 0644)
   * bootstrap the daemon
5. Checks for Tailscale and prints its status.
6. Reports whether SSH (22) and Screen Sharing (5900) are listening. It never turns them on for you.
7. Runs diagnostics and prints the final status.

### Permissions requested

| Permission | When | Why |
|---|---|---|
| Administrator password (`sudo`) | `--with-helper` only | Install the root helper, which is needed for `pmset disablesleep` and pf. |
| None for the agent | always | Assertions, IOKit reads, NWPathMonitor, the Tailscale CLI and NSWorkspace work unprivileged. |
| Local Network (macOS 15+, possible prompt) | first probe | macOS may ask whether the agent may reach devices on the local network. Tailscale access does not depend on it. |
| Sharing services | manual | Remote Login and Screen Sharing are turned on by you in System Settings. |

No Full Disk Access, Accessibility, Screen Recording or kernel extensions are needed.

## Recommended settings for 24/7 use

```bash
sudo pmset -a autorestart 1      # power on after a power failure
```

* In **Settings → Always-On**, keep "Apply on AC power" on, and choose a battery behaviour and threshold.
* For lid-closed use: use AC + an external display (Apple's closed-display mode), **or** install
  the helper and enable "Keep running with the lid closed".
* Use Tailscale's **open-source `tailscaled`** if the Mac must be reachable after a reboot
  before anyone logs in. The GUI variants connect only after login.
* FileVault: after a reboot, someone must unlock the Mac at the login window. This project
  does not ask you to disable FileVault.

## Upgrade

Run `Scripts/install.sh` again. Configuration in `~/Library/Application Support/MacAlwaysOn` is kept.

## Uninstall

```bash
Scripts/uninstall.sh                # everything, including config and logs
Scripts/uninstall.sh --keep-config  # keep config.json
```

The uninstaller:

1. boots out the agent, which stops the command services it supervises, and removes its plist;
2. if the helper is installed, runs `alwaysonhelper --revert-all` (restores `disablesleep 0` if
   the helper set it, and flushes the pf anchor and releases its pf reference), boots out the
   daemon, and removes the binary, plist, state, allow-list, socket and helper logs;
3. quits and deletes the app;
4. deletes `~/Library/Logs/MacAlwaysOn` and, unless `--keep-config` is given,
   `~/Library/Application Support/MacAlwaysOn`.

**Tailscale is not removed.** Remote Login and Screen Sharing settings are not changed.

## Building in Xcode

* `open Package.swift` builds and tests all targets and runs `alwaysond` from Xcode, **or**
* `brew install xcodegen && xcodegen generate && open MacAlwaysOn.xcodeproj`, which gives a
  proper app target that embeds the agent and helper.

## Manual agent control

```bash
launchctl print gui/$(id -u)/com.macalwayson.agent       # state
launchctl kickstart -k gui/$(id -u)/com.macalwayson.agent  # restart
/Applications/MacAlwaysOn.app/Contents/MacOS/alwaysond --status
/Applications/MacAlwaysOn.app/Contents/MacOS/alwaysond --diagnose
```
