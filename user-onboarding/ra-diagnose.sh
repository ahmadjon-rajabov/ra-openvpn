#!/bin/bash
# ============================================================
# ra-openvpn — Client-side Diagnostic Capture
# Captures full state snapshots around connect/disconnect cycles
# Usage:
#   sudo bash ovpn-diagnose.sh <label>
# Where <label> is like "round1-before", "round1-connected",
# "round1-after-ctrlc", "round2-before-retry", "round2-failed"
# ============================================================

set -uo pipefail

LABEL="${1:?Usage: $0 <label>}"
OUT_DIR="/tmp/ovpn-diag"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/${LABEL}-$(date +%H%M%S).txt"

{
    echo "============================================"
    echo "SNAPSHOT: $LABEL"
    echo "TIMESTAMP: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "============================================"
    echo

    echo "--- OpenVPN processes ---"
    ps auxf | grep -E "openvpn|nm-openvpn" | grep -v grep
    echo

    echo "--- Tunnel interfaces ---"
    ip -br addr show | grep -E "tun|tap|utun" || echo "(no tunnel interfaces)"
    echo

    echo "--- All interfaces ---"
    ip -br addr show
    echo

    echo "--- Tunnel interface details (tun0, tun1) ---"
    for i in tun0 tun1 tun2; do
        if ip link show "$i" &>/dev/null; then
            echo "=== $i ==="
            ip -s link show "$i"
            ip addr show "$i"
        fi
    done
    echo

    echo "--- Full route table ---"
    ip route show table all | head -40
    echo

    echo "--- Route decisions for key targets ---"
    for t in 10.99.99.1 192.168.7.20 192.168.5.1 172.31.54.20 8.8.8.8; do
        echo "ip route get $t:"
        ip route get "$t" 2>&1
    done
    echo

    echo "--- Established/listening TCP sockets ---"
    ss -tnp 2>/dev/null | grep -E ":443|:1194|:1195" || echo "(none)"
    echo

    echo "--- Firewall state ---"
    echo "== iptables INPUT =="
    iptables -L INPUT -n -v --line-numbers 2>/dev/null | head -15
    echo "== iptables OUTPUT =="
    iptables -L OUTPUT -n -v --line-numbers 2>/dev/null | head -15
    echo "== iptables FORWARD =="
    iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -15
    echo "== iptables NAT POSTROUTING =="
    iptables -t nat -L POSTROUTING -n -v 2>/dev/null | head -10
    echo

    echo "--- UFW status ---"
    ufw status verbose 2>/dev/null || echo "(ufw not available)"
    echo

    echo "--- NetworkManager state ---"
    nmcli connection show --active 2>/dev/null
    echo
    nmcli device status 2>/dev/null
    echo

    echo "--- Recent syslog for openvpn (last 30 lines) ---"
    journalctl --since "5 minutes ago" 2>/dev/null | grep -iE "openvpn|nm-openvpn" | tail -30
    echo

    echo "--- Sysctl networking essentials ---"
    for k in net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter; do
        echo "  $k = $(sysctl -n $k)"
    done
    echo

    echo "--- Conntrack table (tunnel-related) ---"
    conntrack -L 2>/dev/null | grep -E "10\.99\.99|172\.31\.54\.20|192\.168\.[567]\." | head -20 || echo "(conntrack tool or entries not found)"
    echo

    echo "=== END SNAPSHOT: $LABEL ==="
} > "$OUT" 2>&1

echo "Snapshot saved to: $OUT"
echo "Lines: $(wc -l < "$OUT")"
