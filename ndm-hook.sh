#!/bin/sh

# KeeneticOS hook installed into both /opt/etc/ndm/ifstatechanged.d and
# /opt/etc/ndm/neighbour.d. It runs the trigger right away when the UI switch
# changes state or a policy client appears or changes its address, so the
# periodic poll is only needed for health checks and policy membership.
# ndm waits for hooks, so the trigger is always started in the background.

export PATH="/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
# ndm passes Entware's LD_LIBRARY_PATH, which breaks the firmware ndmc.
unset LD_LIBRARY_PATH LD_BIND_NOW

CONFIG_FILE="/opt/etc/adguard-vpn-trigger.conf"
SCRIPT="/opt/scripts/adguard-vpn-trigger.sh"
LOG="/opt/var/log/adguard-vpn-trigger.hook"
STATE_FILE="/opt/var/run/adguardvpn.state"
CLIENTS_FILE="/opt/var/run/adguardvpn.clients"
MACS_FILE="/opt/var/run/adguardvpn-trigger/policy.macs"
LOCK_DIR="/opt/var/run/adguardvpn-trigger.lock"
PENDING_DIR="/opt/var/run/adguardvpn-trigger.pending"
SWITCH_IF=""

if [ -r "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

[ -n "$SWITCH_IF" ] && [ -x "$SCRIPT" ] || exit 0

case "$0" in
    */ifstatechanged.d/*)
        [ "$id" = "$SWITCH_IF" ] || exit 0
        ;;
    */neighbour.d/*)
        # Only while the VPN is on, and only for policy clients whose address
        # is not routed yet; ARP refreshes of known clients are ignored.
        [ -f "$STATE_FILE" ] && [ -s "$MACS_FILE" ] || exit 0
        env | grep -qiF -f "$MACS_FILE" || exit 0
        new_ip=$(env | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -vxF -f "$CLIENTS_FILE" 2>/dev/null | head -n 1)
        [ -n "$new_ip" ] || exit 0
        ;;
    *)
        exit 0
        ;;
esac

# One toggle produces several events; queue at most one pending run.
mkdir "$PENDING_DIR" 2>/dev/null || exit 0

(
    # Wait for a running poll cycle instead of being dropped by its lock.
    i=0
    while [ -d "$LOCK_DIR" ] && [ "$i" -lt 60 ]; do
        sleep 1
        i=$((i + 1))
    done
    rmdir "$PENDING_DIR" 2>/dev/null
    {
        echo "$(date) hook ${0##*/} from ${0%/*}"
        "$SCRIPT"
    } > "$LOG" 2>&1
) </dev/null >/dev/null 2>&1 &

exit 0
