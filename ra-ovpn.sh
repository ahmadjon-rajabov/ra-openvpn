#!/usr/bin/env bash
# =====================================================================
# ra-ovpn.sh — Management helper for the RA OpenVPN Docker stack
#
# All file & config validation is delegated to ra-validate.sh.
# For read-only commands (down, logs, status), validation is skipped.
# Use --no-validate to skip validation on mutating commands too.
# =====================================================================

set -euo pipefail

# --- Resolve script directory (follows symlinks) ---
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    TARGET="$(readlink "$SOURCE")"
    [[ $TARGET == /* ]] && SOURCE="$TARGET" || SOURCE="$(dirname "$SOURCE")/$TARGET"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yaml"
ENV_FILE="${SCRIPT_DIR}/.env"
VALIDATE_SCRIPT="${SCRIPT_DIR}/ra-validate.sh"

DC="sudo docker compose -f $COMPOSE_FILE --env-file $ENV_FILE"

require_validator() {
    if [[ ! -x "$VALIDATE_SCRIPT" ]]; then
        echo "Required script not found or not executable: $VALIDATE_SCRIPT"
        echo "The validator is mandatory for mutating commands."
        echo "Either install it, or re-run with --no-validate to bypass at your own risk."
        exit 2
    fi
}

validate() {
    require_validator
    "$VALIDATE_SCRIPT" || {
        echo ""
        echo "Validation failed — refusing to proceed. Fix issues above or use --no-validate."
        exit 1
    }
    echo ""
}

# --- Parse flags ---
NO_VALIDATE=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-validate) NO_VALIDATE=1 ;;
        *)             ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]:-}"

CMD="${1:-help}"

# --- Wrapper that runs validate unless bypassed ---
maybe_validate() {
    if [[ $NO_VALIDATE -eq 1 ]]; then
        echo "Skipping validation (--no-validate)"
    else
        validate
    fi
}

case "$CMD" in
    up)       maybe_validate; $DC up -d ;;
    down)     $DC down ;;
    restart)  maybe_validate; $DC restart ;;
    logs)     $DC logs -f "${2:-}" ;;
    status|ps) $DC ps ;;
    validate) require_validator; "$VALIDATE_SCRIPT" ;;
    pull)     $DC pull ;;
    update)   maybe_validate; $DC pull && $DC up -d ;;
    shell)    $DC exec "${2:-ra-openvpn}" /bin/sh ;;
    dir)      echo "$SCRIPT_DIR" ;;
    help|*)
        printf '%s\n' \
"RA OpenVPN — management helper" \
"" \
"Usage:  ra-ovpn <command> [--no-validate]" \
"" \
"Commands (auto-validate: up, restart, update):" \
"  up             Validate + start the stack (detached)" \
"  down           Stop and remove containers" \
"  restart        Validate + restart both containers" \
"  logs [svc]     Follow logs (svc: ra-openvpn | ra-openvpn-ui)" \
"  status         Show container status" \
"  validate       Run pre-flight validation only" \
"  pull           Pull latest images" \
"  update         Validate + pull + restart" \
"  shell [svc]    Open shell in container (default: ra-openvpn)" \
"  dir            Print the project directory" \
"  help           Show this help" \
"" \
"Flags:" \
"  --no-validate  Skip validation for up/restart/update (use with caution)"
        ;;
esac
