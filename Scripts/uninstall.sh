#!/bin/bash
# Removes MacAlwaysOn completely: app, LaunchAgent, optional helper (after reverting any
# pmset / pf change it made), configuration and logs. Tailscale is NOT touched.
#
#   Scripts/uninstall.sh                remove everything
#   Scripts/uninstall.sh --keep-config  keep ~/Library/Application Support/MacAlwaysOn
set -uo pipefail

KEEP_CONFIG=0
for arg in "$@"; do
    case "$arg" in
        --keep-config) KEEP_CONFIG=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 64 ;;
    esac
done

AGENT_LABEL="com.macalwayson.agent"
HELPER_LABEL="com.macalwayson.helper"
USER_ID="$(id -u)"
if [[ "$USER_ID" == "0" ]]; then echo "Run as your normal user (sudo is requested only for the helper)." >&2; exit 1; fi

echo "==> Stopping the agent (command services it supervises are stopped with it)"
launchctl bootout "gui/$USER_ID/$AGENT_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

if [[ -f "/Library/LaunchDaemons/$HELPER_LABEL.plist" || -x "/Library/PrivilegedHelperTools/$HELPER_LABEL" ]]; then
    echo "==> Removing the privileged helper (sudo)"
    sudo /bin/bash -s <<'ROOT'
LABEL=com.macalwayson.helper
if [[ -x "/Library/PrivilegedHelperTools/$LABEL" ]]; then
    "/Library/PrivilegedHelperTools/$LABEL" --revert-all || echo "revert-all failed; check 'pmset -g' and 'pfctl -a com.apple/250.MacAlwaysOn -s rules'"
fi
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" "/var/run/$LABEL.sock"
rm -rf "/Library/Application Support/MacAlwaysOn" /Library/Logs/MacAlwaysOn
ROOT
fi

echo "==> Removing the application"
osascript -e 'tell application id "com.macalwayson.app" to quit' >/dev/null 2>&1 || true
pkill -x MacAlwaysOn 2>/dev/null || true
rm -rf /Applications/MacAlwaysOn.app "$HOME/Applications/MacAlwaysOn.app"

echo "==> Removing logs$( [[ $KEEP_CONFIG == 1 ]] || echo ' and configuration')"
rm -rf "$HOME/Library/Logs/MacAlwaysOn" /tmp/com.macalwayson.agent.stderr.log
if [[ "$KEEP_CONFIG" == 0 ]]; then
    rm -rf "$HOME/Library/Application Support/MacAlwaysOn"
fi

echo
echo "MacAlwaysOn removed. Tailscale, Remote Login and Screen Sharing settings were not changed."
SLEEP_DISABLED="$(pmset -g | awk '/SleepDisabled/ {print $2}')"
if [[ "$SLEEP_DISABLED" == "1" ]]; then
    echo "NOTE: pmset SleepDisabled is still 1 (it was not set by MacAlwaysOn, or revert failed)."
    echo "      To restore normal sleep: sudo pmset -a disablesleep 0"
fi
