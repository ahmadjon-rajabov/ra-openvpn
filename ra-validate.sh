#!/usr/bin/env bash
# =====================================================================
# ra-validate.sh — Pre-flight check for RA OpenVPN configuration
#
# Verifies:
#   * File existence checks (.env, docker-compose.yaml)
#   * Schema-driven checks on every required variable
#   * docker compose config validation
#
# Exit codes:
#   0 = all good, safe to proceed
#   1 = validation failed, DO NOT proceed
#   2 = script setup problem (missing dependency, wrong CWD, etc.)
# =====================================================================

set -euo pipefail

# --- Resolve script directory (follows symlinks) ---
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    TARGET="$(readlink "$SOURCE")"
    [[ $TARGET == /* ]] && SOURCE="$TARGET" || SOURCE="$(dirname "$SOURCE")/$TARGET"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yaml"

# Colors
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
pass() { echo -e "  ${GRN}!!!${NC} $1"; }
fail() { echo -e "  ${RED}!!!${NC} $1"; }
warn() { echo -e "  ${YEL}!!!${NC} $1"; }
info() { echo -e "  ${BLU}!!!${NC}  $1"; }

# =====================================================================
# SCHEMA — single source of truth
# Format:  "VAR_NAME|TYPE|REQUIRED|DESCRIPTION"
# Types:   port | protocol | cidr | iface | ip | bool | secret | string | image
# =====================================================================
SCHEMA=(
    "COMPOSE_PROJECT_NAME|string|yes|Compose project namespace"

    "RA_OPENVPN_CONTAINER_NAME|string|yes|Name of the OpenVPN container"
    "RA_OPENVPN_UI_CONTAINER_NAME|string|yes|Name of the OpenVPN Web UI container"

    "RA_OPENVPN_IMAGE|image|yes|Docker image for OpenVPN server"
    "RA_OPENVPN_UI_IMAGE|image|yes|Docker image for OpenVPN Web UI"

    "RA_OPENVPN_HOST_PORT|port|yes|Host port OpenVPN listens on"
    "RA_OPENVPN_CONTAINER_PORT|port|yes|Container-side port (usually 1194)"
    "RA_OPENVPN_PROTO|protocol|yes|Transport protocol (tcp or udp)"

    "RA_OPENVPN_UI_BIND_LOCAL|ip|yes|Loopback bind IP for UI (usually 127.0.0.1)"
    "RA_OPENVPN_UI_BIND_LAN|ip|yes|LAN bind IP for UI (workstation LAN IP)"
    "RA_OPENVPN_UI_PORT|port|yes|Port the Web UI listens on"
    "RA_OPENVPN_UI_CONTAINER_PORT|port|yes|Container-internal port the UI process listens on (fixed by image, 8080)"

    "RA_OPENVPN_ADMIN_USERNAME|string|yes|Web UI admin username"
    "RA_OPENVPN_ADMIN_PASSWORD|secret|yes|Web UI admin password"

    "RA_TRUST_SUB|cidr|yes|Trusted subnets pushed to clients"
    "RA_GUEST_SUB|cidr|yes|Guest subnets pushed to clients"
    "RA_HOME_SUB|cidr|yes|Home/LAN subnets pushed to clients"

    "RA_VPN_CLIENT_SUBNET|cidr|yes|Subnet assigned to VPN clients"

    "RA_LAN_INTERFACE|iface|yes|Physical NIC on the workstation (e.g., eno1)"
    "RA_UI_ALLOWED_SUBNETS|string|yes|Space-separated CIDR list allowed to reach the UI"

    "RA_DOCKER_NET_NAME|string|yes|Name of the docker bridge network"
    "RA_DOCKER_NET_SUBNET|cidr|yes|Subnet for docker bridge network"

    "RA_RESTART_POLICY|string|yes|Docker restart policy (unless-stopped, always, no)"
)

ERRORS=0
WARNS=0

echo "==> RA OpenVPN pre-flight validation"
echo ""
echo "[1/4] Checking required files..."

if [[ ! -f "$ENV_FILE" ]]; then
    fail ".env not found at $ENV_FILE"
    exit 1
else
    pass ".env exists"
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
    fail "docker-compose.yaml not found at $COMPOSE_FILE"
    exit 1
else
    pass "docker-compose.yaml exists"
fi

# --- Load .env into environment ---
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# =======================================================================
# TYPE VALIDATORS — each returns 0 on success, prints error and returns 1
# =======================================================================
check_port() {
    local var=$1 val=$2 desc=$3
    if [[ ! "$val" =~ ^[0-9]+$ ]] || (( val < 1 || val > 65535 )); then
        fail "$var ($desc): '$val' is not a valid port (1-65535)"
        return 1
    fi
}

check_protocol() {
    local var=$1 val=$2 desc=$3
    case "${val,,}" in
        tcp) ;;
        *) fail "$var ($desc): '$val' must be 'tcp'"; return 1 ;;
    esac
}

check_cidr() {
    local var=$1 val=$2 desc=$3
    if [[ ! "$val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        fail "$var ($desc): '$val' is not valid CIDR (expected x.x.x.x/y)"
        return 1
    fi
}

check_ip() {
    local var=$1 val=$2 desc=$3
    if [[ ! "$val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        fail "$var ($desc): '$val' is not a valid IPv4 address"
        return 1
    fi
}

check_iface() {
    local var=$1 val=$2 desc=$3
    if ! ip link show "$val" >/dev/null 2>&1; then
        fail "$var ($desc): interface '$val' does not exist on this host"
        info "Available interfaces: $(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')"
        return 1
    fi
}

check_secret() {
    local var=$1 val=$2 desc=$3
    if [[ "$val" == "CHANGE_ME_STRONG_PASSWORD" ]] || [[ "$val" == "changeme" ]]; then
        fail "$var ($desc): still set to placeholder — change it!"
        return 1
    fi
    return 0
}

check_image() {
    local var=$1 val=$2 desc=$3
    # Basic sanity: image should look like [registry/]name[:tag]
    if [[ ! "$val" =~ ^[a-z0-9._/-]+(:[a-zA-Z0-9._-]+)?$ ]]; then
        fail "$var ($desc): '$val' doesn't look like a valid image reference"
        return 1
    fi
    if [[ "$val" == *:latest ]]; then
        warn "$var ($desc): uses ':latest' tag — pin to a specific version for reproducibility"
        WARNS=$((WARNS+1))
    fi
}

check_string() {
    local var=$1 val=$2 desc=$3
    # Any non-empty string is fine (emptiness already checked in [2/4])
    return 0
}

echo ""
echo "[2/4] Checking required variables in .env..."

for row in "${SCHEMA[@]}"; do
    IFS='|' read -r var type required desc <<< "$row"
    if ! grep -qE "^${var}=" "$ENV_FILE"; then
        [[ "$required" == "yes" ]] && { fail "Missing: $var ($desc)"; ERRORS=$((ERRORS+1)); }
    else
        val="${!var:-}"
        if [[ -z "$val" && "$required" == "yes" ]]; then
            fail "Empty:   $var ($desc)"
            ERRORS=$((ERRORS+1))
        fi
    fi
done

[[ $ERRORS -eq 0 ]] && pass "All required variables present and non-empty"

echo ""
echo "[3/4] Validating variable values (types & ranges)..."

TYPE_ERRORS=0
for row in "${SCHEMA[@]}"; do
    IFS='|' read -r var type required desc <<< "$row"
    val="${!var:-}"
    # Skip if empty (already reported in step 2)
    [[ -z "$val" ]] && continue

    case "$type" in
        port)     check_port     "$var" "$val" "$desc" || TYPE_ERRORS=$((TYPE_ERRORS+1)) ;;
        protocol) check_protocol "$var" "$val" "$desc" || TYPE_ERRORS=$((TYPE_ERRORS+1)) ;;
        cidr)     check_cidr     "$var" "$val" "$desc" || TYPE_ERRORS=$((TYPE_ERRORS+1)) ;;
        ip)       check_ip       "$var" "$val" "$desc" || TYPE_ERRORS=$((TYPE_ERRORS+1)) ;;
        iface)    check_iface    "$var" "$val" "$desc" || TYPE_ERRORS=$((TYPE_ERRORS+1)) ;;
        secret)   check_secret   "$var" "$val" "$desc" || TYPE_ERRORS=$((TYPE_ERRORS+1)) ;;
        image)    check_image    "$var" "$val" "$desc" || TYPE_ERRORS=$((TYPE_ERRORS+1)) ;;
        string)   check_string   "$var" "$val" "$desc" || TYPE_ERRORS=$((TYPE_ERRORS+1)) ;;
        *)        warn "$var: unknown type '$type' in schema"; WARNS=$((WARNS+1)) ;;
    esac
done

ERRORS=$((ERRORS + TYPE_ERRORS))
[[ $TYPE_ERRORS -eq 0 ]] && pass "All values look valid"

# --- Check for unknown variables (typos) ---
mapfile -t ENV_VARS < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | cut -d= -f1)
for v in "${ENV_VARS[@]}"; do
    found=0
    for row in "${SCHEMA[@]}"; do
        IFS='|' read -r sv _ _ _ <<< "$row"
        [[ "$v" == "$sv" ]] && { found=1; break; }
    done
    if [[ $found -eq 0 ]]; then
        warn "Unknown variable in .env: $v (typo? or missing from schema?)"
        WARNS=$((WARNS+1))
    fi
done

echo ""
echo "[4/4] Validating docker-compose.yaml..."

if sudo docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config -q 2>/tmp/ra-compose-err; then
    pass "docker-compose.yaml parses cleanly"
else
    fail "docker-compose.yaml validation failed:"
    sed 's/^/     /' /tmp/ra-compose-err
    ERRORS=$((ERRORS+1))
fi
rm -f /tmp/ra-compose-err

echo ""
if [[ $ERRORS -eq 0 ]]; then
    if [[ $WARNS -gt 0 ]]; then
        echo -e "${GRN} Validation passed${NC} with ${YEL}$WARNS warning(s)${NC} — safe to proceed."
    else
        echo -e "${GRN} Validation passed — configuration looks great.${NC}"
    fi
    exit 0
else
    echo -e "${RED}Validation failed with $ERRORS error(s).${NC} Fix .env and retry."
    exit 1
fi
