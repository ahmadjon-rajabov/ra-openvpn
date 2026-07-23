#!/usr/bin/env bash
# ra-nm-cleanup.sh — Undo everything ra-nm-import.sh did.
# Usage: sudo ./ra-nm-cleanup.sh <connection-name-or-.ovpn-file>
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root: sudo $0 $*" >&2
    exit 1
fi

ARG="${1:?Usage: sudo ./ra-nm-cleanup.sh <connection-name-or-file.ovpn>}"

if [[ -f "$ARG" ]]; then
    NAME="$(basename "$ARG" .ovpn)"
else
    NAME="$ARG"
fi

DISPATCHER=/etc/NetworkManager/dispatcher.d/90-ra-openvpn-route
CONF_DIR=/etc/ra-openvpn
CONF_FILE="$CONF_DIR/client.env"

# Get RA_SERVER from the config file (if still present) for route cleanup
RA_SERVER=""
[[ -r "$CONF_FILE" ]] && RA_SERVER="$(awk -F= '/^RA_SERVER=/ {print $2; exit}' "$CONF_FILE")"

# --- Delete the imported NM connection --- 
if nmcli -t -f NAME connection show | grep -qx "$NAME"; then
    nmcli connection delete "$NAME"
    echo "Removed NM connection '$NAME'."
else
    echo "ℹNo NM connection named '$NAME' — skipping."
fi

# --- Remove the dispatcher ---
[[ -f "$DISPATCHER" ]] && { rm -f "$DISPATCHER"; echo "Removed $DISPATCHER."; }

# --- Remove the config file & directory ---
[[ -f "$CONF_FILE" ]] && rm -f "$CONF_FILE"
[[ -d "$CONF_DIR"  ]] && rmdir --ignore-fail-on-non-empty "$CONF_DIR"
echo "Removed $CONF_DIR."

# --- Remove the live /32 route --------------------------------------------
if [[ -n "$RA_SERVER" ]]; then
    ip route del "$RA_SERVER/32" 2>/dev/null && \
        echo "Removed live route to $RA_SERVER/32." || true
fi

echo "Done. eduVPN configuration was not modified."

