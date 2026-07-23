#!/usr/bin/env bash
# ra-nm-import.sh — One-time setup for a ra-openvpn Linux client.
# Usage: sudo ./ra-nm-import.sh <path-to-file.ovpn>
#
# Installs three things on the local machine:
#   1. An imported NetworkManager connection for split-tunnel operation.
#   2. /etc/ra-openvpn/client.env with the ra-openvpn server IP.
#   3. /etc/NetworkManager/dispatcher.d/90-ra-openvpn-route (copied verbatim).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root: sudo $0 $*" >&2
    exit 1
fi

OVPN="${1:?Usage: sudo ./ra-nm-import.sh <path-to-file.ovpn>}"
NAME="$(basename "$OVPN" .ovpn)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DISPATCHER_SRC="$SCRIPT_DIR/90-ra-openvpn-route"
DISPATCHER_DST=/etc/NetworkManager/dispatcher.d/90-ra-openvpn-route
CONF_DIR=/etc/ra-openvpn
CONF_FILE="$CONF_DIR/client.env"

# --- Sanity checks -----------------------------------------------------------
[[ -f "$OVPN" ]]           || { echo "ERROR: $OVPN not found" >&2; exit 1; }
[[ -f "$DISPATCHER_SRC" ]] || { echo "ERROR: $DISPATCHER_SRC missing (bundle incomplete)" >&2; exit 1; }

RA_SERVER="$(awk '/^remote / {print $2; exit}' "$OVPN")"
[[ -n "$RA_SERVER" ]]      || { echo "ERROR: no 'remote' directive in $OVPN" >&2; exit 1; }

# --- 1. Import the .ovpn into NetworkManager (split-tunnel) ------------------
nmcli connection import type openvpn file "$OVPN"
nmcli connection modify "$NAME" ipv4.never-default yes
nmcli connection modify "$NAME" ipv6.never-default yes
nmcli connection modify "$NAME" connection.autoconnect no
nmcli connection modify "$NAME" ipv6.method ignore

# --- 2. Write /etc/ra-openvpn/client.env -------------------------------------
install -d -m 0755 "$CONF_DIR"
umask 022
cat > "$CONF_FILE" <<EOF
# Managed by ra-nm-import.sh — do not edit by hand.
RA_SERVER=$RA_SERVER
EOF
chmod 0644 "$CONF_FILE"

# --- 3. Install the dispatcher (copy, don't generate) ------------------------
install -m 0755 -o root -g root "$DISPATCHER_SRC" "$DISPATCHER_DST"

# --- 4. Install the route right now if eduVPN is up --------------------------
GW="$(ip -o route get "$RA_SERVER" 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' || true)"
if [[ -n "$GW" ]]; then
    ip route replace "$RA_SERVER/32" via "$GW" dev tun0
    echo "Route to $RA_SERVER installed via $GW on tun0."
else
    echo "ℹeduVPN not up — the dispatcher will install the route when it connects."
fi

echo "Imported NM connection '$NAME'."
echo "Wrote config      $CONF_FILE"
echo "Installed dispatcher $DISPATCHER_DST"
echo "Toggle the VPN on from the Network menu."

