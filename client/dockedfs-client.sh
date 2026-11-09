#!/bin/sh
# DockedFS client helper. Wraps iscsiadm + cryptsetup + mount.
#
# Usage: sudo -E ./dockedfs-client.sh <command>
#   connect     log in to the host's iSCSI target
#   init        FIRST TIME ONLY: LUKS-format the remote disk and make a filesystem
#   mount       connect (if needed), unlock and mount
#   umount      unmount, lock and log out
#   grow        pick up a larger STORAGE_SIZE from the host
#   status      show session, mapping and mount state
#   chap        print the CHAP login derived from DOCKEDFS_AUTHKEY
#
# Settings come from the environment or from a config file
# (DOCKEDFS_CONFIG, default /etc/dockedfs/client.conf):
#   DOCKEDFS_HOST      tailnet name or IP of the host    (default: dockedfs)
#   DOCKEDFS_PORT      iSCSI port                        (default: 3260)
#   DOCKEDFS_IQN       target name  (default: iqn.2026-11.io.dockedfs:storage)
#   DOCKEDFS_AUTHKEY   the Tailscale auth key you gave the host; the CHAP
#                      login is derived from it (same as the host does)
#   CHAP_USER, CHAP_PASSWORD   explicit login instead, if the host set one
#   CHAP_DISABLE=true  the host runs without CHAP
#   DOCKEDFS_NAME      device-mapper name                (default: dockedfs)
#   DOCKEDFS_MOUNT     mount point                       (default: /mnt/dockedfs)
#   DOCKEDFS_FS        filesystem for init               (default: xfs)
#   DOCKEDFS_KEYFILE   optional LUKS key file; otherwise you are prompted
#   DOCKEDFS_ASSUME_YES=1  skip the "erase this disk?" confirmation in init
set -eu

CONFIG="${DOCKEDFS_CONFIG:-/etc/dockedfs/client.conf}"
# shellcheck disable=SC1090
[ -r "$CONFIG" ] && . "$CONFIG"

HOST="${DOCKEDFS_HOST:-dockedfs}"
PORT="${DOCKEDFS_PORT:-3260}"
IQN="${DOCKEDFS_IQN:-iqn.2026-11.io.dockedfs:storage}"
NAME="${DOCKEDFS_NAME:-dockedfs}"
MNT="${DOCKEDFS_MOUNT:-/mnt/dockedfs}"
FS="${DOCKEDFS_FS:-xfs}"
KEYFILE="${DOCKEDFS_KEYFILE:-}"
BATCH=""; [ "${DOCKEDFS_ASSUME_YES:-0}" = 1 ] && BATCH="--batch-mode"

die() { echo "dockedfs: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' (try: apt-get install $2)"; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo -E $0 ...)"
need iscsiadm open-iscsi
need cryptsetup cryptsetup

if [ -z "${CHAP_USER:-}" ] && [ -n "${DOCKEDFS_AUTHKEY:-}" ]; then
  CHAP_USER=dockedfs
  CHAP_PASSWORD=$(printf %s "$DOCKEDFS_AUTHKEY" | sha256sum | cut -c1-16)
fi
if [ -z "${CHAP_USER:-}" ] && [ "${CHAP_DISABLE:-false}" != "true" ] && [ "${1:-}" != status ]; then
  die "set DOCKEDFS_AUTHKEY (the auth key you gave the host), or CHAP_USER/CHAP_PASSWORD, or CHAP_DISABLE=true"
fi

# Resolve a tailnet name to an IP; iscsiadm and /dev/disk/by-path want an IP.
case "$HOST" in
  *[!0-9.]*)
    if command -v tailscale >/dev/null 2>&1 && ip=$(tailscale ip -4 "$HOST" 2>/dev/null); then
      HOST="$ip"
    else
      ip=$(getent ahostsv4 "$HOST" | awk '{print $1; exit}') || true
      [ -n "$ip" ] || die "cannot resolve host '$HOST'"
      HOST="$ip"
    fi ;;
esac

PORTAL="$HOST:$PORT"
DISK="/dev/disk/by-path/ip-$PORTAL-iscsi-$IQN-lun-1"
MAPPER="/dev/mapper/$NAME"
iscsi() { iscsiadm -m node -T "$IQN" -p "$PORTAL" "$@"; }
luks_key() { [ -n "$KEYFILE" ] && echo "--key-file=$KEYFILE" || true; }

logged_in() { iscsiadm -m session 2>/dev/null | grep -q " $PORTAL,[0-9]* $IQN"; }

connect() {
  if logged_in; then return 0; fi
  # Add the node by IP rather than via sendtargets: the host runs Tailscale in
  # userspace mode, so discovery advertises an unreachable container address.
  iscsi >/dev/null 2>&1 || iscsi -o new >/dev/null
  if [ -n "${CHAP_USER:-}" ]; then
    [ -n "${CHAP_PASSWORD:-}" ] || die "CHAP_USER is set but CHAP_PASSWORD is not"
    iscsi -o update -n node.session.auth.authmethod -v CHAP
    iscsi -o update -n node.session.auth.username -v "$CHAP_USER"
    iscsi -o update -n node.session.auth.password -v "$CHAP_PASSWORD"
  else
    iscsi -o update -n node.session.auth.authmethod -v None
  fi
  iscsi --login >/dev/null
  i=0
  until [ -b "$DISK" ]; do
    i=$((i + 1)); [ "$i" -gt 30 ] && die "logged in but $DISK never appeared"
    sleep 1
  done
  echo "connected: $DISK -> $(readlink -f "$DISK")"
}

unlock() {
  [ -b "$MAPPER" ] && return 0
  # shellcheck disable=SC2046
  cryptsetup open $(luks_key) "$DISK" "$NAME"
}

init() {
  connect
  if cryptsetup isLuks "$DISK"; then
    die "$DISK already holds a LUKS volume; refusing to overwrite it"
  fi
  echo "This will ERASE the remote disk $DISK ($(lsblk -dno SIZE "$(readlink -f "$DISK")"))."
  # shellcheck disable=SC2046
  cryptsetup luksFormat $BATCH --type luks2 --sector-size 4096 $(luks_key) "$DISK"
  unlock
  case "$FS" in
    xfs) mkfs.xfs -q "$MAPPER" ;;
    ext4) mkfs.ext4 -q "$MAPPER" ;;
    *) "mkfs.$FS" "$MAPPER" ;;
  esac
  hdr="./dockedfs-luks-header-$(date +%Y%m%d).img"
  cryptsetup luksHeaderBackup "$DISK" --header-backup-file "$hdr"
  echo "LUKS header backed up to $hdr. Store it (and your passphrase) somewhere other than this disk."
  do_mount
}

do_mount() {
  connect
  unlock
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || mount "$MAPPER" "$MNT"
  echo "mounted: $MNT"
}

do_umount() {
  if mountpoint -q "$MNT"; then umount "$MNT"; fi
  if [ -b "$MAPPER" ]; then cryptsetup close "$NAME"; fi
  if logged_in; then iscsi --logout >/dev/null; fi
  echo "disconnected"
}

grow() {
  logged_in || die "not connected"
  iscsiadm -m session --rescan >/dev/null
  # shellcheck disable=SC2046
  cryptsetup resize $(luks_key) "$NAME"
  case "$(findmnt -no FSTYPE "$MNT")" in
    xfs) xfs_growfs "$MNT" ;;
    ext4) resize2fs "$MAPPER" ;;
    *) die "grow your filesystem on $MAPPER manually" ;;
  esac
  df -h "$MNT"
}

status() {
  echo "portal:  $PORTAL"
  if logged_in; then echo "session: logged in ($DISK)"; else echo "session: not logged in"; fi
  if [ -b "$MAPPER" ]; then echo "luks:    unlocked ($MAPPER)"; else echo "luks:    locked"; fi
  if mountpoint -q "$MNT"; then df -h "$MNT" | tail -1 | awk '{print "mount:   "$6" ("$3" used of "$2")"}'; else echo "mount:   not mounted"; fi
}

case "${1:-}" in
  connect) connect ;;
  init) init ;;
  mount) do_mount ;;
  umount|unmount|disconnect) do_umount ;;
  grow) grow ;;
  status) status ;;
  chap) echo "CHAP_USER=${CHAP_USER:-}"; echo "CHAP_PASSWORD=${CHAP_PASSWORD:-}" ;;
  *) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
