#!/bin/bash
# Installs MacAlwaysOn for the current user.
#
#   Scripts/install.sh                 app + user LaunchAgent (no admin rights needed
#                                      unless /Applications is not writable)
#   Scripts/install.sh --with-helper   also install the optional root helper (asks for sudo)
#   Scripts/install.sh --skip-build    use an existing build/MacAlwaysOn.app
#
# It never installs Tailscale, never changes sharing settings, never touches your router.
set -euo pipefail
cd "$(dirname "$0")/.."

WITH_HELPER=0
SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --with-helper) WITH_HELPER=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 64 ;;
    esac
done

AGENT_LABEL="com.macalwayson.agent"
HELPER_LABEL="com.macalwayson.helper"
USER_ID="$(id -u)"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*"; }

if [[ "$(uname -s)" != "Darwin" ]]; then echo "macOS only." >&2; exit 1; fi
if [[ "$USER_ID" == "0" ]]; then echo "Run as your normal user, not with sudo. The script asks for sudo only for the helper." >&2; exit 1; fi
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MAJOR < 13 )); then echo "macOS 13 or later is required (found $(sw_vers -productVersion))." >&2; exit 1; fi

# 1. Build
if [[ "$SKIP_BUILD" == 0 ]]; then
    step "1/7 Building"
    Scripts/build-app.sh
fi
[[ -d build/MacAlwaysOn.app ]] || { echo "build/MacAlwaysOn.app not found" >&2; exit 1; }

# 2. Install the application
step "2/7 Installing the application"
if [[ -w /Applications ]]; then APP_DIR=/Applications; else APP_DIR="$HOME/Applications"; mkdir -p "$APP_DIR"; fi
APP="$APP_DIR/MacAlwaysOn.app"
if launchctl print "gui/$USER_ID/$AGENT_LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$USER_ID/$AGENT_LABEL" 2>/dev/null || true
fi
pkill -x MacAlwaysOn 2>/dev/null || true
rm -rf "$APP"
ditto build/MacAlwaysOn.app "$APP"
echo "Installed $APP"

# 3. Register the LaunchAgent (runs as you, starts at login, restarts if it exits)
step "3/7 Registering the background agent (LaunchAgent)"
PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__AGENT_PATH__#$APP/Contents/MacOS/alwaysond#" Resources/LaunchAgents/$AGENT_LABEL.plist > "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$USER_ID" "$PLIST"
launchctl enable "gui/$USER_ID/$AGENT_LABEL"
launchctl kickstart -k "gui/$USER_ID/$AGENT_LABEL"
echo "Agent registered: $PLIST"

# 4. Optional privileged helper
step "4/7 Privileged helper"
if [[ "$WITH_HELPER" == 1 ]]; then
    echo "The helper runs as root and can only: toggle 'pmset disablesleep' under a lease, and load a"
    echo "tailnet-only pf anchor. It is needed for lid-closed operation without an external display."
    sudo /bin/bash -s "$APP" "$USER_ID" <<'ROOT'
set -euo pipefail
APP="$1"; USER_ID="$2"
LABEL=com.macalwayson.helper
launchctl bootout "system/$LABEL" 2>/dev/null || true
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools "/Library/Application Support/MacAlwaysOn" /Library/Logs/MacAlwaysOn
install -o root -g wheel -m 755 "$APP/Contents/Library/Helpers/alwaysonhelper" "/Library/PrivilegedHelperTools/$LABEL"
install -o root -g wheel -m 644 "$APP/Contents/Library/LaunchDaemons/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.plist"
AUTH="/Library/Application Support/MacAlwaysOn/helper-authorized-uids"
{ [[ -f "$AUTH" ]] && cat "$AUTH"; echo "$USER_ID"; } | grep -E '^[0-9]+$' | sort -u > "$AUTH.tmp"
mv "$AUTH.tmp" "$AUTH"
chown root:wheel "$AUTH"; chmod 644 "$AUTH"
launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"
ROOT
    echo "Helper installed."
else
    echo "Skipped (optional). Re-run with --with-helper for lid-closed operation without a display"
    echo "or to restrict SSH/Screen Sharing to Tailscale with pf."
fi

# 5. Tailscale
step "5/7 Checking Tailscale"
TS=""
for c in /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do
    [[ -x "$c" ]] && { TS="$c"; break; }
done
if [[ -z "$TS" ]]; then
    warn "Tailscale is not installed. Remote access requires it."
    echo "  Install from https://tailscale.com/download/mac (Standalone recommended), sign in, then re-run diagnostics."
else
    echo "Found: $TS"
    "$TS" status --peers=false 2>&1 | head -5 || warn "Tailscale is installed but not running or not signed in."
fi

# 6. Sharing services (never changed automatically)
step "6/7 Remote-access services"
for port in 22 5900; do
    if nc -z -G 2 127.0.0.1 "$port" >/dev/null 2>&1; then echo "Port $port: listening"; else echo "Port $port: off"; fi
done
echo "Enable Remote Login (SSH) and/or Screen Sharing in System Settings → General → Sharing if you need them."

# 7. Diagnostics and final status
step "7/7 Diagnostics"
AGENT="$APP/Contents/MacOS/alwaysond"
for _ in $(seq 1 20); do
    [[ -S "$HOME/Library/Application Support/MacAlwaysOn/run/agent.sock" ]] && break
    sleep 1
done
"$AGENT" --diagnose || true
echo
"$AGENT" --status || true

cat <<EOM

Done.
  App:        $APP  (menu bar + dashboard; the agent runs without it)
  Agent:      launchctl print gui/$USER_ID/$AGENT_LABEL
  Logs:       ~/Library/Logs/MacAlwaysOn/
  Uninstall:  Scripts/uninstall.sh
EOM
open "$APP" || true
