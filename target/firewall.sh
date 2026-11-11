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
#   - Inbound, only loopback, replies, and WireGuard UDP from public addresses.
#     Port 3260 is not reachable from the host or its LAN at all.
#
# DOCKEDFS_TEST_PUBLISH=true (tests only) also lets the Docker gateway reach
# port 3260 so a test can publish it on localhost without Tailscale.
set -eu

IN=DOCKEDFS-IN
OUT=DOCKEDFS-OUT
TGT_UID=$(id -u tgt)

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
