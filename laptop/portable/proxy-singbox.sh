#!/usr/bin/env bash
# Route all of this PC's traffic through the iPhone SOCKS5 relay, using sing-box.
#
# Usage:  sudo ./proxy-singbox.sh up          run in the foreground; Ctrl+C stops it
#         sudo ./proxy-singbox.sh up info     same, logging every connection
#         sudo ./proxy-singbox.sh down        clean up if a run was killed
#
# Needs the sing-box binary (1.12 or newer) next to this script.

# ---- EDIT THESE ----
PROXY_IP="10.42.0.10"     # the phone's address, as shown in the app
PROXY_PORT="9876"         # SOCKS5 port shown in the phone app
# --------------------

LOG_LEVEL="${2:-warn}"                          # warn | info | debug
TUN="tun0"
TUN_DNS="172.19.0.2"                            # inside the tun subnet; sing-box answers it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGBOX="$SCRIPT_DIR/sing-box"
CONFIG="$SCRIPT_DIR/proxy-singbox.json"
RESOLV_BACKUP="/etc/resolv.conf.proxy-tun-backup"
NFT_TABLE="proxy_singbox"
OTHER_LINKS=()

write_config() {
    local hotspot_dev="$1" hotspot_net="$2"
    # DNS is resolved over TCP through the phone, and apps get real addresses.
    # UDP timeout: sing-box gives connections it recognises as STUN a 10 s idle
    # timeout, which tears down voice calls mid-handshake.
    cat > "$CONFIG" <<EOF
{
  "log": { "level": "$LOG_LEVEL", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "tcp", "tag": "remote", "server": "2606:4700:4700::1111", "detour": "phone" }
    ],
    "final": "remote",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "$TUN",
      "address": ["172.19.0.1/30"],
      "mtu": 9000,
      "auto_route": true,
      "strict_route": true,
      "route_exclude_address": ["$hotspot_net"]
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "phone",
      "server": "$PROXY_IP",
      "server_port": $PROXY_PORT,
      "version": "5",
      "bind_interface": "$hotspot_dev"
    }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "network": "udp", "action": "route-options", "udp_timeout": "5m" }
    ],
    "final": "phone",
    "default_interface": "$hotspot_dev"
  }
}
EOF
}

block_forward() {
    # Don't let the hotspot pass the phone's own traffic on to the internet:
    # it would go into tun0 and straight back to the phone.
    nft -f - <<EOF
table inet $NFT_TABLE {
    chain forward {
        type filter hook forward priority -10; policy accept;
        iifname "$1" reject
    }
}
EOF
}

unblock_forward() {
    nft delete table inet "$NFT_TABLE" 2>/dev/null
}

dns_on() {
    # Send every lookup to sing-box, and keep other interfaces' DNS out of it.
    resolvectl dns "$TUN" "$TUN_DNS"
    resolvectl dnsovertls "$TUN" no     # sing-box answers plain DNS only
    resolvectl domain "$TUN" '~.'
    resolvectl default-route "$TUN" yes
    for link in $(resolvectl dns | grep -oP '^Link \d+ \(\K[^)]+'); do
        [ "$link" = "$TUN" ] && continue
        resolvectl default-route "$link" no 2>/dev/null
        OTHER_LINKS+=("$link")
    done
    resolvectl flush-caches
    if [ "$(readlink -f /etc/resolv.conf)" != "/run/systemd/resolve/stub-resolv.conf" ]; then
        cp -a /etc/resolv.conf "$RESOLV_BACKUP"
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
}

dns_off() {
    for link in "${OTHER_LINKS[@]}"; do
        resolvectl default-route "$link" yes 2>/dev/null
    done
    if [ -e "$RESOLV_BACKUP" ]; then
        rm -f /etc/resolv.conf
        mv "$RESOLV_BACKUP" /etc/resolv.conf
    fi
    resolvectl flush-caches 2>/dev/null
}

down() {
    [ -n "$SB_PID" ] && kill "$SB_PID" 2>/dev/null && wait "$SB_PID" 2>/dev/null
    ip link delete "$TUN" 2>/dev/null
    unblock_forward
    dns_off
    echo "Proxy stopped, DNS restored."
}

up() {
    if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo."; exit 1; fi
    if [ ! -x "$SINGBOX" ]; then
        echo "sing-box not found or not executable at $SINGBOX"; exit 1
    fi
    if ! ip route get "$PROXY_IP" >/dev/null 2>&1; then
        echo "No route to $PROXY_IP. Is the phone connected to the hotspot?"; exit 1
    fi

    ip link delete "$TUN" 2>/dev/null   # left over from a killed run

    local hotspot_dev hotspot_net
    hotspot_dev=$(ip route get "$PROXY_IP" | grep -oP 'dev \K\S+')
    hotspot_net=$(ip -4 route show dev "$hotspot_dev" scope link | awk '{print $1; exit}')
    [ -z "$hotspot_net" ] && hotspot_net="$PROXY_IP/32"

    write_config "$hotspot_dev" "$hotspot_net"
    "$SINGBOX" check -c "$CONFIG" || { echo "Config check failed (see above)."; exit 1; }

    modprobe tun 2>/dev/null
    "$SINGBOX" run -c "$CONFIG" &
    SB_PID=$!
    trap down EXIT INT TERM

    for _ in $(seq 50); do ip link show "$TUN" >/dev/null 2>&1 && break; sleep 0.1; done
    if ! ip link show "$TUN" >/dev/null 2>&1; then
        echo "sing-box failed to create $TUN (see log above)."; exit 1
    fi

    dns_on
    unblock_forward
    block_forward "$hotspot_dev" || echo "Warning: couldn't block hotspot forwarding (nft failed)."
    echo "Routing all traffic via the phone at $PROXY_IP:$PROXY_PORT (log level $LOG_LEVEL). Ctrl+C to stop."
    wait "$SB_PID"
}

case "$1" in
    up)   up ;;
    down) down ;;
    *)    echo "Usage: sudo $0 up [warn|info|debug] | down"; exit 1 ;;
esac
