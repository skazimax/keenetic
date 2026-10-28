#!/bin/sh

set -u

export PATH="/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SWITCH_IF=""
POLICY_NAME="Policy0"
TABLE_ID="100"
RULE_PRIORITY="90"
ADGUARD_HOME="/opt/home/adguardvpn"
HEALTHCHECK_URL="https://www.google.com/generate_204"
HEALTHCHECK_PARALLEL="4"
ADGUARD_LOG_MAX_KB="1024"
PROTOCOLS="quic http2"
INTERVAL="120"
CONFIG_FILE="/opt/etc/adguard-vpn-trigger.conf"

# A reinstall keeps the existing configuration; command-line options override it.
if [ -r "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

INSTALL_PACKAGES=1
INSTALL_ADGUARD=1
START_SERVICE=1

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --switch NAME          Dedicated Keenetic UI switch interface
                         (required unless already set in the existing config)
  --policy NAME          Keenetic client policy (default: existing or Policy0)
  --interval SECONDS     Polling interval (default: existing or 120)
  --skip-packages        Do not run opkg update/install
  --skip-adguard         Do not install AdGuard VPN CLI
  --no-start             Install files without starting the service
  -h, --help             Show this help
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

safe_name() {
    case "$1" in
        ""|*[!A-Za-z0-9_.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

safe_number() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] 2>/dev/null ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --switch)
            [ "$#" -ge 2 ] || die "--switch requires a value"
            SWITCH_IF="$2"
            shift 2
            ;;
        --policy)
            [ "$#" -ge 2 ] || die "--policy requires a value"
            POLICY_NAME="$2"
            shift 2
            ;;
        --interval)
            [ "$#" -ge 2 ] || die "--interval requires a value"
            INTERVAL="$2"
            shift 2
            ;;
        --skip-packages)
            INSTALL_PACKAGES=0
            shift
            ;;
        --skip-adguard)
            INSTALL_ADGUARD=0
            shift
            ;;
        --no-start)
            START_SERVICE=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

[ "$(id -u)" = "0" ] || die "run this installer as root"
[ -x /opt/bin/opkg ] || die "Entware is not mounted at /opt; install and start OPKG first"
[ -n "$SWITCH_IF" ] || die "--switch is required (no SWITCH_IF in $CONFIG_FILE)"
safe_name "$SWITCH_IF" || die "invalid switch interface name: $SWITCH_IF"
safe_name "$POLICY_NAME" || die "invalid policy name: $POLICY_NAME"
safe_number "$INTERVAL" || die "invalid interval: $INTERVAL"
[ "$INTERVAL" -ge 15 ] || die "interval must be at least 15 seconds"

for file in adguard-vpn-trigger.sh S99adguard-vpn-trigger adguard-vpn-selftest.sh ndm-hook.sh; do
    [ -f "$SCRIPT_DIR/$file" ] || die "missing deployment file: $SCRIPT_DIR/$file"
done

if [ "$INSTALL_PACKAGES" -eq 1 ]; then
    log "updating Entware package index"
    opkg update || die "opkg update failed"
    log "installing runtime packages"
    opkg install curl ca-certificates iptables sudo || die "failed to install Entware packages"
fi

mkdir -p "$ADGUARD_HOME" /opt/scripts /opt/etc/init.d /opt/etc /opt/var/run /opt/var/log /opt/tmp || die "failed to create runtime directories"
chmod 700 "$ADGUARD_HOME" || die "failed to protect $ADGUARD_HOME"

if [ "$INSTALL_ADGUARD" -eq 1 ] && [ ! -x /opt/adguardvpn_cli/adguardvpn-cli ]; then
    log "installing the official AdGuard VPN CLI release"
    INSTALLER="/opt/tmp/adguardvpn-install.sh"
    curl -fsSL "https://raw.githubusercontent.com/AdguardTeam/AdGuardVPNCLI/master/scripts/release/install.sh" -o "$INSTALLER" || die "failed to download AdGuard installer"
    chmod 700 "$INSTALLER"
    (
        cd /opt || exit 1
        USER=root HOME="$ADGUARD_HOME" SSL_CERT_FILE=/opt/etc/ssl/certs/ca-certificates.crt sh "$INSTALLER" -v -a n
    ) || die "AdGuard VPN CLI installation failed"
fi

[ -x /opt/adguardvpn_cli/adguardvpn-cli ] || die "AdGuard VPN CLI is missing; install it or rerun without --skip-adguard"
ln -sf /opt/adguardvpn_cli/adguardvpn-cli /opt/bin/adguardvpn-cli || die "failed to create AdGuard VPN CLI symlink"

STAMP=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="/opt/backup/adguard-vpn-trigger/$STAMP"
mkdir -p "$BACKUP_DIR" || die "failed to create backup directory"

backup_file() {
    [ -e "$1" ] || return 0
    cp -p "$1" "$BACKUP_DIR/$(basename "$1")" || die "failed to back up $1"
}

SERVICE="/opt/etc/init.d/S99adguard-vpn-trigger"
if [ -x "$SERVICE" ]; then
    "$SERVICE" stop >/dev/null 2>&1 || true
fi

backup_file /opt/scripts/adguard-vpn-trigger.sh
backup_file "$SERVICE"
backup_file "$CONFIG_FILE"
backup_file /opt/bin/adguard-vpn-selftest

HOOK_NAME="50-adguard-vpn-trigger.sh"
HOOK_DIRS="/opt/etc/ndm/ifstatechanged.d /opt/etc/ndm/neighbour.d"
for dir in $HOOK_DIRS; do
    [ -e "$dir/$HOOK_NAME" ] && { cp -p "$dir/$HOOK_NAME" "$BACKUP_DIR/${dir##*/}-$HOOK_NAME" || die "failed to back up $dir/$HOOK_NAME"; }
done

# Disable the all-clients hooks from the official example if they exist. They
# conflict with Policy0 selection; copies remain in the timestamped backup.
for hook in /opt/etc/ndm/netfilter.d/001-adguardvpn.sh /opt/etc/ndm/wan.d/001-adguardvpn.sh; do
    if [ -e "$hook" ]; then
        case "$hook" in
            */netfilter.d/*) cp -p "$hook" "$BACKUP_DIR/ndm-netfilter-001-adguardvpn.sh" || die "failed to back up $hook" ;;
            */wan.d/*) cp -p "$hook" "$BACKUP_DIR/ndm-wan-001-adguardvpn.sh" || die "failed to back up $hook" ;;
        esac
        mv "$hook" "$hook.disabled-$STAMP" || die "failed to disable $hook"
        log "disabled conflicting hook: $hook"
    fi
done

cp "$SCRIPT_DIR/adguard-vpn-trigger.sh" /opt/scripts/adguard-vpn-trigger.sh || die "failed to install trigger"
cp "$SCRIPT_DIR/S99adguard-vpn-trigger" "$SERVICE" || die "failed to install startup script"
cp "$SCRIPT_DIR/adguard-vpn-selftest.sh" /opt/bin/adguard-vpn-selftest || die "failed to install self-test"
chmod 755 /opt/scripts/adguard-vpn-trigger.sh "$SERVICE" /opt/bin/adguard-vpn-selftest || die "failed to set executable permissions"

for dir in $HOOK_DIRS; do
    mkdir -p "$dir" || die "failed to create $dir"
    cp "$SCRIPT_DIR/ndm-hook.sh" "$dir/$HOOK_NAME" || die "failed to install hook into $dir"
    chmod 755 "$dir/$HOOK_NAME" || die "failed to set hook permissions"
done

CONFIG_TMP="$CONFIG_FILE.tmp"
{
    echo "SWITCH_IF=\"$SWITCH_IF\""
    echo "POLICY_NAME=\"$POLICY_NAME\""
    echo "TABLE_ID=\"$TABLE_ID\""
    echo "RULE_PRIORITY=\"$RULE_PRIORITY\""
    echo "ADGUARD_HOME=\"$ADGUARD_HOME\""
    echo "HEALTHCHECK_URL=\"$HEALTHCHECK_URL\""
    echo "HEALTHCHECK_PARALLEL=\"$HEALTHCHECK_PARALLEL\""
    echo "ADGUARD_LOG_MAX_KB=\"$ADGUARD_LOG_MAX_KB\""
    echo "PROTOCOLS=\"$PROTOCOLS\""
    echo "INTERVAL=\"$INTERVAL\""
} > "$CONFIG_TMP"
chmod 600 "$CONFIG_TMP" || die "failed to protect configuration"
mv "$CONFIG_TMP" "$CONFIG_FILE" || die "failed to install configuration"

if [ ! -e /dev/net/tun ]; then
    echo "WARNING: /dev/net/tun is missing; install/enable the Keenetic VPN components" >&2
fi

if [ "$START_SERVICE" -eq 1 ]; then
    log "starting adguard-vpn-trigger"
    "$SERVICE" start || die "service failed to start"
fi

log "installation complete"
echo "Backup: $BACKUP_DIR"
echo "Next: export HOME=$ADGUARD_HOME and run /opt/bin/adguardvpn-cli login"
echo "Check: /opt/bin/adguard-vpn-selftest"
