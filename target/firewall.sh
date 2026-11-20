#!/bin/sh
# DockedFS host firewall. Runs once at start, as root, inside the network
# namespace shared by the tailscale and target containers.
#
# Goal: the host's LAN and the rest of its network are invisible from here.
#   - The iSCSI server (user "tgt") may only talk over loopback, which is where
#     userspace Tailscale delivers tailnet connections. It has no network at all.
#   - Nothing in here may reach private, link-local or CGNAT addresses, i.e. the
#     host's LAN, router, NAS, or cloud metadata services.
#   - Out to the public internet, only what Tailscale uses: HTTPS (control
#     server, DERP relays), HTTP (captive-portal and DERP fallback) and UDP
#     (WireGuard to peers, STUN). DNS goes to Docker's resolver on loopback.
#   - A custom control server (TS_LOGIN_SERVER, e.g. Headscale) is also allowed,
#     on its own port, even when it lives on a private address. Only that
#     address and port (plus STUN, UDP 3478, for an embedded DERP) are opened.
#   - Inbound, only loopback, replies, and WireGuard UDP from public addresses.
#     Port 3260 is not reachable from the host or its LAN at all.
#
# DOCKEDFS_TEST_PUBLISH=true (tests only) also lets the Docker gateway reach
# port 3260 so a test can publish it on localhost without Tailscale.
set -eu

IN=DOCKEDFS-IN
OUT=DOCKEDFS-OUT
TGT_UID=$(id -u tgt)

log() { echo "[dockedfs] $*"; }

# --- Custom control server (TS_LOGIN_SERVER) ---------------------------------
# Accepts http(s)://host[:port][/path], with host a name, IPv4 or [IPv6].
CTRL_PORT=
CTRL_IPS=
if [ -n "${TS_LOGIN_SERVER:-}" ]; then
  case "$TS_LOGIN_SERVER" in
    https://*) CTRL_PORT=443 ;;
    http://*) CTRL_PORT=80 ;;
    *) log "ERROR: TS_LOGIN_SERVER must start with https:// or http:// (got: $TS_LOGIN_SERVER)"; exit 1 ;;
  esac
  hostport=${TS_LOGIN_SERVER#*://}
  hostport=${hostport%%/*}
  hostport=${hostport##*@}
  case "$hostport" in
    \[*\]:*) CTRL_HOST=${hostport%%]*}; CTRL_HOST=${CTRL_HOST#\[}; CTRL_PORT=${hostport##*]:} ;;
    \[*\]) CTRL_HOST=${hostport#\[}; CTRL_HOST=${CTRL_HOST%]} ;;
    *:*) CTRL_HOST=${hostport%:*}; CTRL_PORT=${hostport##*:} ;;
    *) CTRL_HOST=$hostport ;;
  esac
  case "$CTRL_PORT" in
    ''|*[!0-9]*) log "ERROR: can't read a port from TS_LOGIN_SERVER ($TS_LOGIN_SERVER)"; exit 1 ;;
  esac
  CTRL_IPS=$(getent ahosts "$CTRL_HOST" 2>/dev/null | awk '{print $1}' | sort -u || true)
  if [ -n "$CTRL_IPS" ]; then
    log "Firewall: allowing control server $CTRL_HOST port $CTRL_PORT ($(echo "$CTRL_IPS" | paste -sd' ' -))"
  else
    log "WARNING: could not resolve $CTRL_HOST from TS_LOGIN_SERVER; only public HTTPS/HTTP will get through"
  fi
fi

PRIVATE4="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4"
PRIVATE6="fc00::/7 fe80::/10 ff00::/8 ::ffff:0:0/96 64:ff9b::/96"

setup() { # $1 = iptables|ip6tables, $2 = private ranges
  t=$1
  $t -N $IN 2>/dev/null || $t -F $IN
  $t -N $OUT 2>/dev/null || $t -F $OUT
  $t -C INPUT -j $IN 2>/dev/null || $t -I INPUT 1 -j $IN
  $t -C OUTPUT -j $OUT 2>/dev/null || $t -I OUTPUT 1 -j $OUT

  # --- outbound ---
  $t -A $OUT -o lo -j ACCEPT
  if [ "${DOCKEDFS_TEST_PUBLISH:-false}" = true ] && [ "$t" = iptables ]; then
    $t -A $OUT -m owner --uid-owner "$TGT_UID" -p tcp --sport 3260 -m conntrack --ctstate ESTABLISHED -j ACCEPT
  fi
  $t -A $OUT -m owner --uid-owner "$TGT_UID" -j REJECT
  if [ "$t" = ip6tables ]; then
    # Neighbor discovery and router solicitation, or IPv6 doesn't work at all.
    for type in 133 135 136 143; do $t -A $OUT -p ipv6-icmp --icmpv6-type $type -j ACCEPT; done
  fi
  # Custom control server: before the private-range block, so a LAN or VPN
  # address works too. Only its exact address and port are opened.
  for ip in $CTRL_IPS; do
    case "$ip" in *:*) [ "$t" = ip6tables ] || continue ;; *) [ "$t" = iptables ] || continue ;; esac
    $t -A $OUT -d "$ip" -p tcp --dport "$CTRL_PORT" -j ACCEPT
    $t -A $OUT -d "$ip" -p udp --dport 3478 -j ACCEPT
  done
  for net in $2; do $t -A $OUT -d "$net" -j REJECT; done
  $t -A $OUT -p udp -j ACCEPT
  $t -A $OUT -p tcp -m multiport --dports 443,80 -j ACCEPT
  $t -A $OUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  $t -A $OUT -j REJECT

  # --- inbound ---
  $t -A $IN -i lo -j ACCEPT
  if [ "${DOCKEDFS_TEST_PUBLISH:-false}" = true ] && [ "$t" = iptables ]; then
    $t -A $IN -s "$GW" -p tcp --dport 3260 -j ACCEPT
  fi
  if [ "$t" = ip6tables ]; then
    for type in 134 135 136; do $t -A $IN -p ipv6-icmp --icmpv6-type $type -j ACCEPT; done
  fi
  $t -A $IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  for net in $2; do $t -A $IN -s "$net" -j DROP; done
  $t -A $IN -p udp -j ACCEPT
  $t -A $IN -j DROP
}

GW=$(ip -4 route show default | awk '{print $3; exit}')
setup iptables "$PRIVATE4"
if ip6tables -L >/dev/null 2>&1; then setup ip6tables "$PRIVATE6"; fi
