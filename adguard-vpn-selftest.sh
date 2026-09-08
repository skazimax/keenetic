#!/opt/bin/sh

export PATH="/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

CONFIG_FILE="/opt/etc/adguard-vpn-trigger.conf"
SWITCH_IF=""
POLICY_NAME="Policy0"
TABLE_ID="100"
RULE_PRIORITY="90"
ADGUARD_HOME="/opt/home/adguardvpn"

if [ -r "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

export HOME="$ADGUARD_HOME"
export SSL_CERT_FILE="/opt/etc/ssl/certs/ca-certificates.crt"

ERRORS=0
WARNINGS=0
VPN_CONNECTED=0
RUN_CFG="/opt/var/run/adguardvpn-selftest.running-config"
RUN_CFG_CACHE="/opt/var/run/adguardvpn-trigger/running-config.txt"

ok() { echo "OK   $*"; }
warn() { echo "WARN $*"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "FAIL $*"; ERRORS=$((ERRORS + 1)); }

echo "AdGuard VPN trigger self-test"
echo "switch=$SWITCH_IF policy=$POLICY_NAME table=$TABLE_ID priority=$RULE_PRIORITY"

[ -n "$SWITCH_IF" ] && ok "UI switch interface is configured" || fail "SWITCH_IF is not configured"

[ -x /opt/bin/opkg ] && ok "Entware is available" || fail "Entware is not available at /opt"
if [ -x /opt/bin/adguardvpn-cli ]; then
    ok "AdGuard VPN CLI is installed"
    if command -v timeout >/dev/null 2>&1; then
        timeout 20 /opt/bin/adguardvpn-cli status >/opt/var/run/adguardvpn-selftest.cli-status 2>&1
    else
        /opt/bin/adguardvpn-cli status >/opt/var/run/adguardvpn-selftest.cli-status 2>&1 &
        status_pid=$!
        (sleep 20; kill "$status_pid" 2>/dev/null) &
        watchdog_pid=$!
        wait "$status_pid" 2>/dev/null || true
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi

    if grep -qi 'not logged in' /opt/var/run/adguardvpn-selftest.cli-status; then
        fail "AdGuard VPN profile is not logged in at $ADGUARD_HOME"
    elif grep -qiE '^VPN is connected|^Connected to ' /opt/var/run/adguardvpn-selftest.cli-status; then
        VPN_CONNECTED=1
        ok "AdGuard VPN session is connected"
    else
        VPN_CONNECTED=0
        warn "AdGuard VPN session is disconnected"
    fi
else
    fail "AdGuard VPN CLI is missing"
fi
[ -x /opt/sbin/iptables ] && ok "Entware iptables is installed" || fail "Entware iptables is missing"
[ -x /opt/scripts/adguard-vpn-trigger.sh ] && ok "trigger script is installed" || fail "trigger script is missing"
[ -x /opt/etc/init.d/S99adguard-vpn-trigger ] && ok "startup script is installed" || fail "startup script is missing"
[ -e /dev/net/tun ] && ok "TUN device is available" || fail "/dev/net/tun is missing"
[ -r /opt/etc/ssl/certs/ca-certificates.crt ] && ok "CA certificate bundle is available" || fail "CA certificate bundle is missing"

for hook in /opt/etc/ndm/netfilter.d/001-adguardvpn.sh /opt/etc/ndm/wan.d/001-adguardvpn.sh; do
    [ -e "$hook" ] && warn "conflicting all-clients hook is active: $hook"
done

if [ -f /opt/var/run/adguard-vpn-trigger.pid ] && kill -0 "$(cat /opt/var/run/adguard-vpn-trigger.pid)" 2>/dev/null; then
    ok "polling service is running (pid $(cat /opt/var/run/adguard-vpn-trigger.pid))"
else
    fail "polling service is not running"
fi

SWITCH_ON=0
if ndmc -c "show running-config" > "$RUN_CFG" 2>/dev/null; then
    ok "Keenetic running-config is readable"
elif [ -s "$RUN_CFG_CACHE" ]; then
    cp "$RUN_CFG_CACHE" "$RUN_CFG"
    warn "nested ndmc is unavailable; using the trigger running-config cache"
else
    fail "cannot read Keenetic running-config"
    : > "$RUN_CFG"
fi

if awk -v iface="$SWITCH_IF" '$1 == "interface" && $2 == iface { found=1 } END { exit(found ? 0 : 1) }' "$RUN_CFG"; then
    ok "UI switch interface $SWITCH_IF exists"
else
    fail "UI switch interface $SWITCH_IF does not exist"
fi

if awk -v iface="$SWITCH_IF" '
    $1 == "interface" && $2 == iface { inside=1; on=0; found=1; next }
    inside && $1 == "!" { exit }
    inside && $1 == "up" { on=1 }
    inside && $1 == "down" { on=0 }
    END { exit(found && on ? 0 : 1) }
' "$RUN_CFG"; then
    SWITCH_ON=1
    ok "UI switch is ON"
else
    ok "UI switch is OFF"
fi

POLICY_MACS=$(awk -v policy="$POLICY_NAME" '
    $1 == "host" {
        for (i=1; i<NF; i++) if ($i == "policy" && $(i+1) == policy) count++
    }
    END { print count+0 }
' "$RUN_CFG")

if [ "$POLICY_MACS" -gt 0 ]; then
    ok "$POLICY_NAME contains $POLICY_MACS client(s)"
else
    warn "$POLICY_NAME has no clients, or the policy does not exist"
fi

if [ "$SWITCH_ON" -eq 1 ]; then
    [ "$VPN_CONNECTED" -eq 1 ] && ok "VPN session matches the enabled switch" || fail "switch is ON but VPN session is not connected"
    ip link show tun0 >/dev/null 2>&1 && ok "tun0 is up" || fail "switch is ON but tun0 is down"
    ip route show table "$TABLE_ID" 2>/dev/null | grep -q 'default.*tun0' && ok "VPN route table has a tun0 default route" || fail "VPN route table has no tun0 default route"
    ip rule show 2>/dev/null | grep -q "^$RULE_PRIORITY:.*lookup \($TABLE_ID\|adguardvpn\)" && ok "client policy rule is present" || warn "no client rule at priority $RULE_PRIORITY"
    /opt/sbin/iptables -S FORWARD 2>/dev/null | grep -q ADGUARD_FORWARD && ok "forwarding chain is attached" || fail "ADGUARD_FORWARD is not attached"
else
    ip link show tun0 >/dev/null 2>&1 && warn "switch is OFF but tun0 still exists" || ok "tun0 is down as expected"
fi

if [ -s /opt/var/log/adguard-vpn-trigger.status ]; then
    echo "--- last trigger run ---"
    cat /opt/var/log/adguard-vpn-trigger.status
else
    warn "trigger status log is empty"
fi

echo "--- memory snapshot ---"
free 2>/dev/null || true
ps w 2>/dev/null | awk 'NR == 1 || /[n]dm|[a]dguardvpn|[S]99adguard/'

echo "Result: $ERRORS error(s), $WARNINGS warning(s)"
[ "$ERRORS" -eq 0 ]
