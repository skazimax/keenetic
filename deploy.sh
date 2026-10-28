#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
ROUTER_HOST=""
ROUTER_PORT="22"
ROUTER_USER="root"
# Empty values are not passed, so install.sh keeps the router's existing config.
SWITCH_IF=""
POLICY_NAME=""
INTERVAL=""

usage() {
    cat <<'EOF'
Usage: ./deploy.sh [options]

Options:
  --host ADDRESS       Router address or hostname (required)
  --port PORT          SSH port (default: 22)
  --user USER          SSH user (default: root)
  --switch NAME        Dedicated UI switch interface
                       (required on first install)
  --policy NAME        Client policy (default: existing or Policy0)
  --interval SECONDS   Polling interval (default: existing or 120)
  -h, --help           Show this help

The SSH password is requested by ssh. It is never stored by this script.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

safe_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

safe_number() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

while (($#)); do
    case "$1" in
        --host) (($# >= 2)) || die "--host requires a value"; ROUTER_HOST="$2"; shift 2 ;;
        --port) (($# >= 2)) || die "--port requires a value"; ROUTER_PORT="$2"; shift 2 ;;
        --user) (($# >= 2)) || die "--user requires a value"; ROUTER_USER="$2"; shift 2 ;;
        --switch) (($# >= 2)) || die "--switch requires a value"; SWITCH_IF="$2"; shift 2 ;;
        --policy) (($# >= 2)) || die "--policy requires a value"; POLICY_NAME="$2"; shift 2 ;;
        --interval) (($# >= 2)) || die "--interval requires a value"; INTERVAL="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "$ROUTER_HOST" ] || die "--host is required"
safe_name "$ROUTER_HOST" || die "invalid host"
safe_number "$ROUTER_PORT" || die "invalid port"
safe_name "$ROUTER_USER" || die "invalid user"

INSTALL_ARGS=""
if [ -n "$SWITCH_IF" ]; then
    safe_name "$SWITCH_IF" || die "invalid switch name"
    INSTALL_ARGS+=" --switch '$SWITCH_IF'"
fi
if [ -n "$POLICY_NAME" ]; then
    safe_name "$POLICY_NAME" || die "invalid policy name"
    INSTALL_ARGS+=" --policy '$POLICY_NAME'"
fi
if [ -n "$INTERVAL" ]; then
    safe_number "$INTERVAL" || die "invalid interval"
    ((10#$INTERVAL >= 15)) || die "interval must be at least 15 seconds"
    INSTALL_ARGS+=" --interval '$INTERVAL'"
fi

for command in ssh tar; do
    command -v "$command" >/dev/null || die "$command is not installed locally"
done

FILES=(
    install.sh
    adguard-vpn-trigger.sh
    S99adguard-vpn-trigger
    adguard-vpn-selftest.sh
    ndm-hook.sh
)

for file in "${FILES[@]}"; do
    [[ -f "$SCRIPT_DIR/$file" ]] || die "missing file: $SCRIPT_DIR/$file"
done

REMOTE_DIR="/tmp/adguard-vpn-deploy-$$"
REMOTE_COMMAND="mkdir -p '$REMOTE_DIR' && tar -xf - -C '$REMOTE_DIR' && chmod 700 '$REMOTE_DIR/install.sh' && '$REMOTE_DIR/install.sh'$INSTALL_ARGS && rm -f '$REMOTE_DIR/install.sh' '$REMOTE_DIR/adguard-vpn-trigger.sh' '$REMOTE_DIR/S99adguard-vpn-trigger' '$REMOTE_DIR/adguard-vpn-selftest.sh' '$REMOTE_DIR/ndm-hook.sh' && rmdir '$REMOTE_DIR'"

echo "Deploying to $ROUTER_USER@$ROUTER_HOST:$ROUTER_PORT"
tar -C "$SCRIPT_DIR" -cf - "${FILES[@]}" | ssh -p "$ROUTER_PORT" "$ROUTER_USER@$ROUTER_HOST" "$REMOTE_COMMAND"
status=("${PIPESTATUS[@]}")

if ((status[1] != 0)); then
    die "remote installation failed; uploaded files remain in $REMOTE_DIR"
fi
if ((status[0] != 0)); then
    die "failed to create deployment archive"
fi

echo "Deployment finished. Run the AdGuard login step from README.md before enabling the UI switch."
