#!/opt/bin/sh

export PATH="/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
# ndm hooks and Entware shells export Entware's library path; the firmware
# ndmc binary then fails with "Cli::Main: failed to initialize".
unset LD_LIBRARY_PATH LD_BIND_NOW

CONFIG_FILE="/opt/etc/adguard-vpn-trigger.conf"

# A dedicated Keenetic WireGuard interface is used only as a UI switch.
# Its link state, peers, addresses and handshake status are intentionally ignored.
SWITCH_IF=""
POLICY_NAME="Policy0"
TABLE_ID="100"
RULE_PRIORITY="90"
ADGUARD_HOME="/opt/home/adguardvpn"
HEALTHCHECK_URL="https://www.google.com/generate_204"
HEALTHCHECK_PARALLEL="4"
ADGUARD_LOG_MAX_KB="1024"
PROTOCOLS="quic http2"

if [ -r "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

export HOME="$ADGUARD_HOME"
export SSL_CERT_FILE="/opt/etc/ssl/certs/ca-certificates.crt"

STATE_DIR="/opt/var/run/adguardvpn-trigger"
STATE_FILE="/opt/var/run/adguardvpn.state"
RULES_FILE="/opt/var/run/adguardvpn.rules.applied"
CLIENTS_FILE="/opt/var/run/adguardvpn.clients"
CLIENTS_MAC_FILE="$STATE_DIR/policy.macs"
DESIRED_FILE="$STATE_DIR/desired.clients"
APPLIED_HASH_FILE="$STATE_DIR/applied.hash"
RUN_CFG_FILE="$STATE_DIR/running-config.txt"
DHCP_FILE="$STATE_DIR/dhcp-binding.txt"
VPN_STATUS_FILE="$STATE_DIR/vpn.status"
PROTOCOL_FILE="$STATE_DIR/protocol"
LOCK_DIR="/opt/var/run/adguardvpn-trigger.lock"

VPN_CMD="/opt/bin/adguardvpn-cli"
IPTABLES="/opt/sbin/iptables"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

mkdir -p "$STATE_DIR" /opt/var/run /opt/var/log

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another trigger instance is running, exiting"
    exit 0
fi

trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

require_tools() {
    if [ -z "$SWITCH_IF" ]; then
        log "SWITCH_IF is not configured in $CONFIG_FILE"
        return 1
    fi

    if [ ! -x "$VPN_CMD" ]; then
        log "Missing $VPN_CMD"
        return 1
    fi

    if [ ! -x "$IPTABLES" ]; then
        log "Missing $IPTABLES; install Entware iptables first"
        return 1
    fi

    return 0
}

load_running_config() {
    local tmp="$RUN_CFG_FILE.tmp"

    if ndmc -c "show running-config" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$RUN_CFG_FILE"
        return 0
    fi

    rm -f "$tmp"
    log "Failed to read running-config"
    return 1
}

is_vpn_switch_on() {
    awk -v iface="$SWITCH_IF" '
        $1 == "interface" && $2 == iface { inside = 1; on = 0; found = 1; next }
        inside && $1 == "!" { exit }
        inside && $1 == "up" { on = 1 }
        inside && $1 == "down" { on = 0 }
        END { exit(found && on ? 0 : 1) }
    ' "$RUN_CFG_FILE"
}

write_policy_macs() {
    awk -v policy="$POLICY_NAME" '
        $1 == "host" {
            for (i = 1; i < NF; i++) {
                if ($i == "policy" && $(i + 1) == policy) print tolower($2)
            }
        }
    ' "$RUN_CFG_FILE" | sort -u > "$CLIENTS_MAC_FILE"
}

is_tun_up() {
    ip link show tun0 >/dev/null 2>&1
}

# AdGuard answers ICMP on tun0 locally, so ping succeeds even when the tunnel
# cannot open new connections. Check several parallel TCP/TLS requests instead.
is_tun_healthy() {
    is_tun_up || return 1

    passed=$(
        {
            i=0
            while [ "$i" -lt "$HEALTHCHECK_PARALLEL" ]; do
                curl -s -m 5 --interface tun0 -o /dev/null -w '%{http_code}\n' "$HEALTHCHECK_URL" 2>/dev/null &
                i=$((i + 1))
            done
            wait
        } | grep -c '^[23]'
    )

    [ "$passed" -gt 0 ] && [ $((passed * 2)) -ge "$HEALTHCHECK_PARALLEL" ]
}

load_vpn_status() {
    local tmp="$VPN_STATUS_FILE.tmp"

    run_with_timeout 20 "$VPN_CMD" status > "$tmp" 2>&1
    rc=$?

    mv "$tmp" "$VPN_STATUS_FILE"
    return "$rc"
}

run_with_timeout() {
    seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
        return $?
    fi

    "$@" &
    command_pid=$!
    (sleep "$seconds"; kill "$command_pid" 2>/dev/null) &
    watchdog_pid=$!
    wait "$command_pid"
    rc=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    return "$rc"
}

disable_tun0_ipv6() {
    [ -e /proc/sys/net/ipv6/conf/tun0/disable_ipv6 ] && echo 1 > /proc/sys/net/ipv6/conf/tun0/disable_ipv6 2>/dev/null || true
    [ -e /proc/sys/net/ipv6/conf/tun0/autoconf ] && echo 0 > /proc/sys/net/ipv6/conf/tun0/autoconf 2>/dev/null || true
    [ -e /proc/sys/net/ipv6/conf/tun0/accept_ra ] && echo 0 > /proc/sys/net/ipv6/conf/tun0/accept_ra 2>/dev/null || true
}

clean_tun0_ipv6_routes() {
    ip -6 route show dev tun0 2>/dev/null | while read route; do
        [ -n "$route" ] && ip -6 route del $route 2>/dev/null || true
    done
}

clean_all_vpn_ipv6() {
    [ -d /proc/sys/net/ipv6 ] || return 0
    disable_tun0_ipv6
    clean_tun0_ipv6_routes
}

load_dhcp_binding() {
    local tmp="$DHCP_FILE.tmp"

    if ndmc -c "show ip dhcp binding" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$DHCP_FILE"
        return 0
    fi

    rm -f "$tmp"
    : > "$DHCP_FILE"
    log "Failed to read DHCP bindings, falling back to neighbor table only"
    return 1
}

resolve_clients_from_dhcp() {
    [ -s "$CLIENTS_MAC_FILE" ] || return 0

    awk '
        NR == FNR { wanted[tolower($1)] = 1; next }
        { gsub(/\r/, "") }
        $1 == "ip:" { ip = $2 }
        $1 == "mac:" {
            mac = tolower($2)
            if (wanted[mac] && ip != "") print ip
        }
    ' "$CLIENTS_MAC_FILE" "$DHCP_FILE"
}

resolve_clients_from_neigh() {
    [ -s "$CLIENTS_MAC_FILE" ] || return 0

    while read mac; do
        [ -n "$mac" ] || continue
        ip neigh | awk -v mac="$mac" 'tolower($0) ~ mac && $1 ~ /^[0-9]+\./ { print $1 }'
    done < "$CLIENTS_MAC_FILE"
}

build_desired_clients() {
    write_policy_macs
    : > "$DESIRED_FILE"

    if [ ! -s "$CLIENTS_MAC_FILE" ]; then
        log "No clients assigned to $POLICY_NAME"
        return 0
    fi

    load_dhcp_binding || true

    {
        resolve_clients_from_dhcp
        resolve_clients_from_neigh
    } | sort -u > "$DESIRED_FILE"

    cp "$DESIRED_FILE" "$CLIENTS_FILE"
    log "$POLICY_NAME clients: $(wc -l < "$CLIENTS_MAC_FILE") MAC(s), resolved: $(wc -l < "$DESIRED_FILE") IPv4 address(es)"
}

hash_file() {
    md5sum "$1" 2>/dev/null | awk '{print $1}'
}

clean_ip_rules() {
    ip rule show | awk -v table="$TABLE_ID" '
        /from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ && ($0 ~ "lookup " table || $0 ~ /lookup adguardvpn/) {
            prio=$1
            gsub(":", "", prio)
            print prio, $3
        }
    ' | while read prio src; do
        [ -n "$prio" ] && [ -n "$src" ] && ip rule del priority "$prio" from "$src" table "$TABLE_ID" 2>/dev/null || true
    done
}

clean_nat() {
    $IPTABLES -t nat -S POSTROUTING 2>/dev/null | grep 'tun0' | grep 'MASQUERADE' | while read rule; do
        cmd=$(echo "$rule" | sed 's/^-A /-D /')
        $IPTABLES -t nat $cmd 2>/dev/null || true
    done
}

clean_forward_chain() {
    $IPTABLES -D FORWARD -j ADGUARD_FORWARD 2>/dev/null || true
    $IPTABLES -F ADGUARD_FORWARD 2>/dev/null || true
    $IPTABLES -X ADGUARD_FORWARD 2>/dev/null || true
}

clean_tun0_ipv4_main_routes() {
    ip route show dev tun0 2>/dev/null | while read route; do
        [ -n "$route" ] && ip route del $route 2>/dev/null || true
    done
}

cleanup_rules() {
    log "Cleaning AdGuard VPN routing rules"
    clean_ip_rules
    clean_nat
    clean_forward_chain
    ip route flush table "$TABLE_ID" 2>/dev/null || true
    rm -f "$RULES_FILE" "$APPLIED_HASH_FILE"
}

teardown() {
    cleanup_rules
    stop_vpn_session
    rm -f "$STATE_FILE" "$CLIENTS_FILE" "$CLIENTS_MAC_FILE" "$DESIRED_FILE"
}

# The CLI rotates tunnel.log at 10 MB keeping five copies and never trims
# app.log; on internal flash that is ~60 MB of writes we do not need.
trim_adguard_logs() {
    local dir="$ADGUARD_HOME/.local/share/adguardvpn-cli"
    local size

    rm -f "$dir"/tunnel.log.[2-9]

    [ -f "$dir/app.log" ] || return 0
    size=$(wc -c < "$dir/app.log")
    if [ "$size" -gt $((ADGUARD_LOG_MAX_KB * 1024)) ]; then
        tail -n 2000 "$dir/app.log" > "$dir/app.log.tmp" && cat "$dir/app.log.tmp" > "$dir/app.log"
        rm -f "$dir/app.log.tmp"
    fi
}

stop_vpn_session() {
    local pids_file="$STATE_DIR/tunnel.pids"

    run_with_timeout 15 "$VPN_CMD" disconnect >/dev/null 2>&1 || true

    ps w | awk '$0 ~ /\/opt\/bin\/[a]dguardvpn-cli connect --no-fork/ { print $1 }' > "$pids_file"
    while read pid; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done < "$pids_file"

    sleep 1
    while read pid; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done < "$pids_file"
    rm -f "$pids_file"

    i=0
    while is_tun_up && [ "$i" -lt 5 ]; do
        sleep 1
        i=$((i + 1))
    done

    rm -f "$ADGUARD_HOME/.local/share/adguardvpn-cli/vpn.socket"
}

ensure_vpn_connected() {
    # In "auto" routing mode the CLI routes the whole router through tun0 via
    # the main table; only table $TABLE_ID clients must use the tunnel.
    clean_tun0_ipv4_main_routes

    if is_tun_healthy; then
        return 0
    fi

    if is_tun_up; then
        log "tun0 exists but VPN traffic check failed; resetting stale session"
    else
        log "AdGuard VPN tunnel is down; starting a new session"
    fi

    cleanup_rules
    stop_vpn_session

    load_vpn_status || true
    if grep -qi 'not logged in' "$VPN_STATUS_FILE"; then
        log "AdGuard VPN is not logged in; interactive login is required"
        return 1
    fi

    # Start with the protocol that worked last time, then try the others.
    tried=" "
    for proto in $(cat "$PROTOCOL_FILE" 2>/dev/null) $PROTOCOLS; do
        case "$tried" in *" $proto "*) continue ;; esac
        tried="$tried$proto "

        if connect_with_protocol "$proto"; then
            echo "$proto" > "$PROTOCOL_FILE"
            clean_all_vpn_ipv6
            return 0
        fi
        stop_vpn_session
    done

    log "AdGuard VPN did not reach connected state with any of: $PROTOCOLS"
    return 1
}

connect_with_protocol() {
    log "Connecting AdGuard VPN using $1"

    if ! run_with_timeout 15 "$VPN_CMD" config set-protocol "$1" >/dev/null 2>&1; then
        log "Failed to set AdGuard VPN protocol $1"
        return 1
    fi

    if ! run_with_timeout 30 "$VPN_CMD" connect --yes --fastest </dev/null; then
        clean_tun0_ipv4_main_routes
        log "AdGuard VPN connect command failed or timed out ($1)"
        return 1
    fi
    clean_tun0_ipv4_main_routes

    i=0
    while [ "$i" -lt 10 ]; do
        sleep 2
        clean_tun0_ipv4_main_routes
        is_tun_healthy && return 0
        i=$((i + 1))
    done

    log "AdGuard VPN traffic check failed ($1)"
    return 1
}

rules_present() {
    [ -f "$RULES_FILE" ] || return 1
    ip route show table "$TABLE_ID" 2>/dev/null | grep -q 'default.*tun0' || return 1
    $IPTABLES -S FORWARD 2>/dev/null | grep -q 'ADGUARD_FORWARD' || return 1
    return 0
}

preserve_local_routes() {
    ip route show table main | while read route; do
        case "$route" in
            default*|*tun0*) continue ;;
            192.168.*|10.*)
                ip route replace $route table "$TABLE_ID" 2>/dev/null || true
                ;;
        esac
    done
}

apply_rules() {
    log "Applying AdGuard VPN IPv4-only rules"

    if ! is_tun_up; then
        log "tun0 is not up, skipping rules"
        return 1
    fi

    clean_ip_rules
    clean_nat
    clean_forward_chain
    clean_tun0_ipv4_main_routes

    $IPTABLES -N ADGUARD_FORWARD 2>/dev/null || true
    $IPTABLES -I FORWARD -j ADGUARD_FORWARD
    $IPTABLES -A ADGUARD_FORWARD -o tun0 -j ACCEPT
    $IPTABLES -A ADGUARD_FORWARD -i tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    ip route flush table "$TABLE_ID" 2>/dev/null || true
    preserve_local_routes
    ip route replace default dev tun0 table "$TABLE_ID"

    if [ ! -s "$DESIRED_FILE" ]; then
        log "No resolved VPN clients; route table prepared, no client rules added"
    fi

    $IPTABLES -t nat -A POSTROUTING -o tun0 -j MASQUERADE

    while read ipaddr; do
        [ -n "$ipaddr" ] || continue
        log "Adding VPN client: $ipaddr"
        ip rule add from "$ipaddr/32" table "$TABLE_ID" priority "$RULE_PRIORITY" 2>/dev/null || true
    done < "$DESIRED_FILE"

    clean_all_vpn_ipv6
    touch "$RULES_FILE"
    hash_file "$DESIRED_FILE" > "$APPLIED_HASH_FILE"
}

switch_off() {
    log "$SWITCH_IF switch is OFF"

    if [ -f "$STATE_FILE" ] || [ -f "$RULES_FILE" ] || is_tun_up; then
        teardown
        log "AdGuard VPN stopped"
    else
        log "Nothing to do"
    fi
}

switch_on() {
    log "$SWITCH_IF switch is ON"

    if ! ensure_vpn_connected; then
        teardown
        log "VPN unavailable; policy clients left on the regular gateway"
        return 1
    fi
    build_desired_clients

    desired_hash=$(hash_file "$DESIRED_FILE")
    applied_hash=$(cat "$APPLIED_HASH_FILE" 2>/dev/null)

    if ! rules_present; then
        log "Rules are missing, applying"
        apply_rules
    elif [ "$desired_hash" != "$applied_hash" ]; then
        log "Client set changed, applying"
        apply_rules
    else
        log "VPN already ON, rules are up to date"
    fi

    touch "$STATE_FILE"
}

require_tools || exit 1

if [ "${1:-run}" = "cleanup" ]; then
    teardown
    log "AdGuard VPN stopped and routing state cleaned"
    exit 0
fi

trim_adguard_logs

if ! load_running_config; then
    cleanup_rules
    rm -f "$STATE_FILE" "$CLIENTS_FILE" "$CLIENTS_MAC_FILE" "$DESIRED_FILE"
    log "Keenetic configuration unavailable; policy clients left on the regular gateway"
    exit 1
fi

if is_vpn_switch_on; then
    switch_on
else
    switch_off
fi
