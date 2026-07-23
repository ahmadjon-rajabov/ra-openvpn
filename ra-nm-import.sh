#!/usr/bin/env bash
# ra-nm-import.sh — Import a ra-openvpn .ovpn into NetworkManager
# with correct split-tunnel routing, then leave it usable from the Linux GUI.
set -euo pipefail

OVPN="${1:?Usage: ra-nm-import <path-to-file.ovpn>}"
NAME="$(basename "$OVPN" .ovpn)"

nmcli connection import type openvpn file "$OVPN"

# Split-tunnel: do NOT hijack the default route
nmcli connection modify "$NAME" ipv4.never-default yes
nmcli connection modify "$NAME" ipv6.never-default yes

# hardening / hygiene
nmcli connection modify "$NAME" connection.autoconnect no
nmcli connection modify "$NAME" ipv6.method ignore

echo "Imported '$NAME'. Toggle it on from the Network menu."