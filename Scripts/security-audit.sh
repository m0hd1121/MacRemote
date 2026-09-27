#!/bin/bash
# Read-only security self-check. Verifies that nothing listens publicly because of
# MacAlwaysOn and reports what is reachable from the LAN versus only from Tailscale.
# Run with sudo to also inspect the pf anchor.
set -uo pipefail

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
info() { printf '  INFO  %s\n' "$*"; }

echo "== Listening TCP sockets (all users) =="
netstat -an -p tcp | awk '$NF=="LISTEN" {print $1, $4}' | sort -u | while read -r proto local; do
    addr="${local%.*}"; port="${local##*.}"
    case "$addr" in
        127.*|::1|localhost) info "$proto $addr:$port (loopback only)";;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|fd7a:115c:a1e0:*) ok "$proto $addr:$port (Tailscale only)";;
        '*'|0.0.0.0|::) warn "$proto *:$port listens on ALL interfaces (LAN-reachable; internet-reachable only if your router forwards it)";;
        *) warn "$proto $addr:$port listens on a LAN address";;
    esac
done

echo
echo "== MacAlwaysOn web dashboard =="
if netstat -an -p tcp | awk '$NF=="LISTEN" {print $4}' | grep -Eq '^(\*|0\.0\.0\.0)\.8686$'; then
    warn "Something listens on *:8686 — the MacAlwaysOn dashboard never does this; investigate."
else
    ok "No wildcard listener on the dashboard port"
fi

echo
echo "== pf tailnet-only anchor =="
if [[ "$(id -u)" == "0" ]]; then
    rules="$(pfctl -a com.apple/250.MacAlwaysOn -s rules 2>/dev/null)"
    if [[ -n "$rules" ]]; then ok "anchor loaded:"; echo "$rules" | sed 's/^/        /'; else info "anchor not loaded"; fi
    pfctl -s info 2>/dev/null | head -1 | sed 's/^/        /'
else
    info "run with sudo to inspect pf"
fi

echo
echo "== macOS Application Firewall =="
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | sed 's/^/        /'

echo
echo "== Tailscale =="
TS=""
for c in /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do
    [[ -x "$c" ]] && { TS="$c"; break; }
done
if [[ -n "$TS" ]]; then
    "$TS" status --peers=false 2>&1 | head -3 | sed 's/^/        /'
else
    warn "Tailscale not installed"
fi

echo
echo "== Things this script cannot check =="
info "Router port forwarding / UPnP / NAT-PMP: MacAlwaysOn never configures them. Check your router's"
info "admin page and make sure no rule forwards to this Mac, and consider disabling UPnP."
info "From a device OUTSIDE your network and OUTSIDE Tailscale, 'nc -vz <your public IP> 22' should fail."
