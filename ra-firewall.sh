#!/usr/bin/env bash
# =====================================================================
# ra-firewall.sh — Host firewall configuration for RA OpenVPN
#
# WHAT IT DOES:
#   1. Allows inbound OpenVPN port (from .env)
#   2. Allows Web UI access from private LAN subnets only
#   3. Adds NAT masquerade for VPN client subnet -> physical interface
#   4. Enables kernel IP forwarding (persistent)
#   5. Sets UFW default forward policy to ACCEPT
#
# USAGE:   sudo ./ra-firewall.sh <apply|remove|status>
#
# Rules are tagged 'ra-openvpn' for identification and clean removal.
# =====================================================================

set -euo pipefail

# --- Load .env from script's follows symlinks ---
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    TARGET="$(readlink "$SOURCE")"
    [[ $TARGET == /* ]] && SOURCE="$TARGET" || SOURCE="$(dirname "$SOURCE")/$TARGET"
done

SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo ".env not found at $ENV_FILE — aborting."
    exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# --- Configuration (all required from .env) ---
VPN_PORT="${RA_OPENVPN_HOST_PORT:?RA_OPENVPN_HOST_PORT must be set in .env}"
VPN_PROTO="${RA_OPENVPN_PROTO:?RA_OPENVPN_PROTO must be set in .env}"
UI_PORT="${RA_OPENVPN_UI_PORT:?RA_OPENVPN_UI_PORT must be set in .env}"
VPN_SUBNET="${RA_VPN_CLIENT_SUBNET:?RA_VPN_CLIENT_SUBNET must be set in .env}"
LAN_IF="${RA_LAN_INTERFACE:?RA_LAN_INTERFACE must be set in .env}"
UI_SUBNETS_RAW="${RA_UI_ALLOWED_SUBNETS:?RA_UI_ALLOWED_SUBNETS must be set in .env}"

# Convert space-separated list to array
read -r -a UI_ALLOWED_SUBNETS <<< "$UI_SUBNETS_RAW"

# Tag for identifying our rules (used for cleanup)
TAG="ra-openvpn"

# --- Helpers ---
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Must run as root: sudo $0 $*"
        exit 1
    fi
}

check_deps() {
    command -v ufw >/dev/null || { echo "ufw not installed"; exit 1; }
    command -v iptables >/dev/null || { echo "iptables not installed"; exit 1; }
}

apply_rules() {
    echo "==> Applying firewall rules for RA OpenVPN"
    echo "    VPN port:    ${VPN_PORT}/${VPN_PROTO}"
    echo "    UI port:     ${UI_PORT}/tcp"
    echo "    VPN subnet:  ${VPN_SUBNET}"
    echo "    LAN iface:   ${LAN_IF}"
    echo "    UI subnets:  ${UI_ALLOWED_SUBNETS[*]}"
    echo ""

    echo "[1/6] Enabling IPv4 forwarding..."
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.d/99-${TAG}.conf 2>/dev/null; then
        echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-${TAG}.conf
        sysctl -p /etc/sysctl.d/99-${TAG}.conf >/dev/null
    fi
    echo "      net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward)"

    echo "[2/6] Setting UFW forward policy to ACCEPT..."
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    echo "    Done"

    echo "[3/6] Allowing VPN port ${VPN_PORT}/${VPN_PROTO}..."
    ufw allow proto "${VPN_PROTO}" from any to any port "${VPN_PORT}" comment "${TAG}"
    echo "    Done"

    echo "[4/6] Allowing UI port ${UI_PORT} from private subnets..."
    for subnet in "${UI_ALLOWED_SUBNETS[@]}"; do
        ufw allow proto tcp from "${subnet}" to any port "${UI_PORT}" \
            comment "${TAG}-ui-${subnet//\//_}"
    done
    echo "    Done"

    # Add NAT masquerade rule for VPN clients
    echo "[5/6] NAT masquerade rule for ${VPN_SUBNET} -> ${LAN_IF}..."
    UFW_BEFORE=/etc/ufw/before.rules
    MARKER_BEGIN="# BEGIN ${TAG} NAT"
    MARKER_END="# END ${TAG} NAT"

    if ! grep -q "${MARKER_BEGIN}" "${UFW_BEFORE}"; then
        # Prepend NAT block to before.rules
        tmpfile=$(mktemp)
        {
            echo "${MARKER_BEGIN}"
            echo "*nat"
            echo ":POSTROUTING ACCEPT [0:0]"
            echo "-A POSTROUTING -s ${VPN_SUBNET} -o ${LAN_IF} -j MASQUERADE"
            echo "COMMIT"
            echo "${MARKER_END}"
            echo ""
            cat "${UFW_BEFORE}"
        } > "${tmpfile}"
        mv "${tmpfile}" "${UFW_BEFORE}"
        echo "    NAT block added to ${UFW_BEFORE}"
    else
        echo "    NAT block already present"
    fi

    echo "[6/6] Reloading UFW..."
    ufw reload
    echo "     Done"
    echo ""
    echo "Firewall configured successfully!"
    echo ""
    echo "Verify with:"
    echo "    sudo ufw status verbose"
    echo "    sudo iptables -t nat -L POSTROUTING -n | grep ${VPN_SUBNET%/*}"
}

remove_rules() {
    echo "==> Removing OpenVPN firewall rules"

    while read -r num; do
        [[ -z "$num" ]] && continue
        ufw --force delete "$num"
    done < <(ufw status numbered | grep "${TAG}" | awk -F'[][]' '{print $2}' | sort -rn)

    UFW_BEFORE=/etc/ufw/before.rules
    if grep -q "# BEGIN ${TAG} NAT" "${UFW_BEFORE}"; then
        sed -i "/# BEGIN ${TAG} NAT/,/# END ${TAG} NAT/d" "${UFW_BEFORE}"
        echo "    Removed NAT block from ${UFW_BEFORE}"
    fi

    ufw reload
    echo "🧹 Cleanup complete."
    echo "Note: /etc/sysctl.d/99-${TAG}.conf left in place. Remove manually if desired."
}

show_status() {
    echo "==> Current RA OpenVPN firewall status"
    echo ""
    echo "[UFW rules tagged '${TAG}']"
    ufw status verbose | grep -E "(${TAG}|To|--)" || echo "  (none)"
    echo ""
    echo "[NAT rules in iptables]"
    iptables -t nat -L POSTROUTING -n -v | grep -E "(Chain|${VPN_SUBNET%/*})" || echo "  (none matching ${VPN_SUBNET})"
    echo ""
    echo "[Kernel forwarding]"
    echo "  net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward)"
    echo ""
    echo "[UFW default forward policy]"
    grep DEFAULT_FORWARD_POLICY /etc/default/ufw
}

# --- Main ---
CMD="${1:-status}"
case "$CMD" in
    apply)   require_root; check_deps; apply_rules ;;
    remove)  require_root; check_deps; remove_rules ;;
    status)  check_deps; show_status ;;
    *)
        printf '%s\n' \
"RA OpenVPN — management helper" \
"" \
"Usage: sudo $(basename "$0") <command> [args]" \
"" \
"Commands:" \
"  apply    Apply firewall rules (idempotent, safe to re-run)" \
"  remove   Remove all rules added by this script" \
"  status   Show current firewall state related to RA OpenVPN" \
"" \
"Rules are tagged with '${TAG}' for easy identification/removal." \
        ;;
esac
