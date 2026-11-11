#!/bin/sh
# DockedFS target: serves one sparse (or pre-allocated) disk image over iSCSI
# with CHAP authentication and an optional bandwidth cap.
set -eu

STORAGE_SIZE="${STORAGE_SIZE:?set STORAGE_SIZE in .env, e.g. 500G}"
PREALLOCATE="${PREALLOCATE:-false}"
IMAGE="/storage/disk.img"
IQN="${TARGET_IQN:-iqn.2026-11.io.dockedfs:storage}"
CHAP_USER="${CHAP_USER:-}"
CHAP_PASSWORD="${CHAP_PASSWORD:-}"

log() { echo "[dockedfs] $*"; }

# CHAP login, in order of preference:
#  1. CHAP_USER + CHAP_PASSWORD, if both are set
#  2. derived from the Tailscale auth key: h = sha256(TS_AUTHKEY) in hex,
#     password = h[0:16], username = h[16:32]. Only someone who has seen the key
#     (the client who made it, and this host) can log in, with nothing extra
#     to exchange.
#  3. none, only if CHAP_DISABLE=true
if { [ -n "$CHAP_USER" ] && [ -z "$CHAP_PASSWORD" ]; } || { [ -z "$CHAP_USER" ] && [ -n "$CHAP_PASSWORD" ]; }; then
  log "ERROR: set both CHAP_USER and CHAP_PASSWORD, or neither."
  exit 1
fi
if [ -z "$CHAP_USER" ] && [ "${CHAP_DISABLE:-false}" != "true" ]; then
  [ -n "${TS_AUTHKEY:-}" ] || { log "ERROR: TS_AUTHKEY is needed to derive the CHAP login (keep it in .env after the first start)."; exit 1; }
  h=$(printf %s "$TS_AUTHKEY" | sha256sum)
  CHAP_PASSWORD=$(echo "$h" | cut -c1-16)
  CHAP_USER=$(echo "$h" | cut -c17-32)
  chap_src="derived from TS_AUTHKEY"
else
  chap_src="from CHAP_USER/CHAP_PASSWORD"
fi

# --- Disk image -------------------------------------------------------------
want=$(numfmt --from=iec "$STORAGE_SIZE")

if [ -f "$IMAGE" ]; then
  have=$(stat -c %s "$IMAGE")
  if [ "$want" -lt "$have" ]; then
    log "ERROR: STORAGE_SIZE ($STORAGE_SIZE) is smaller than the existing disk ($(numfmt --to=iec "$have"))."
    log "Refusing to shrink it, because that would destroy your friend's data."
    exit 1
  fi
fi

if [ "$PREALLOCATE" = "true" ]; then
  fallocate -l "$want" "$IMAGE"
elif [ ! -f "$IMAGE" ] || [ "$(stat -c %s "$IMAGE")" -lt "$want" ]; then
  truncate -s "$want" "$IMAGE"
fi
log "Disk: $(numfmt --to=iec "$(stat -c %s "$IMAGE")") offered, $(du -h "$IMAGE" | cut -f1) used on this host"

# --- Bandwidth cap ----------------------------------------------------------
# Shapes all traffic in this network namespace (shared with the tailscale
# container), in both directions. Ingress is redirected through an ifb device
# so it is shaped rather than policed, which keeps TCP throughput near the cap.
dev=$(ip -o route show default | awk '{print $5; exit}')
tc qdisc del dev "$dev" root 2>/dev/null || true
tc qdisc del dev "$dev" ingress 2>/dev/null || true
if [ -n "${MAX_BANDWIDTH_MBIT:-}" ] && [ "${MAX_BANDWIDTH_MBIT}" != "0" ]; then
  rate="${MAX_BANDWIDTH_MBIT}mbit"
  ip link add ifb0 type ifb 2>/dev/null || true
  ip link set ifb0 up
  tc qdisc replace dev "$dev" root tbf rate "$rate" burst 512k latency 200ms
  tc qdisc add dev "$dev" handle ffff: ingress
  tc filter add dev "$dev" parent ffff: matchall action mirred egress redirect dev ifb0
  tc qdisc replace dev ifb0 root tbf rate "$rate" burst 512k latency 200ms
  log "Bandwidth capped at ${MAX_BANDWIDTH_MBIT} Mbit/s in each direction"
fi

# --- iSCSI target -----------------------------------------------------------
tgtd -f &
TGTD=$!
trap 'kill "$TGTD" 2>/dev/null' TERM INT

i=0
until tgtadm --lld iscsi --mode sys --op show >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { log "ERROR: tgtd did not start"; exit 1; }
  sleep 0.5
done

tgtadm --lld iscsi --mode target --op new --tid 1 --targetname "$IQN"
tgtadm --lld iscsi --mode logicalunit --op new --tid 1 --lun 1 --backing-store "$IMAGE"
if [ -n "$CHAP_USER" ]; then
  tgtadm --lld iscsi --mode account --op new --user "$CHAP_USER" --password "$CHAP_PASSWORD"
  tgtadm --lld iscsi --mode account --op bind --tid 1 --user "$CHAP_USER"
  auth="CHAP login $chap_src"
else
  auth="CHAP disabled; access is controlled by the tailnet ACL only"
fi
tgtadm --lld iscsi --mode target --op bind --tid 1 --initiator-address ALL
log "Ready: $IQN on port 3260 ($auth)"

wait "$TGTD"
