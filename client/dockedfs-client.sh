#!/usr/bin/env bash
# DockedFS client.
#
# Run it with no arguments and it walks you through whatever is left to do:
# auth key, picking the host, connecting, encrypting, formatting, mounting,
# mounting at boot, and backing up your keys. Run it again any time; finished
# steps are skipped.
#
# Commands for scripts and day-to-day use:
#   (none)      guided setup / status
#   mount       connect, unlock and mount
#   umount      unmount, lock and disconnect
#   status      show session, unlock and mount state
#   grow        pick up a larger STORAGE_SIZE from the host
#   chap        print the CHAP login derived from the auth key
#   connect     log in to the iSCSI target only
#   init        non-interactive first-time format (needs DOCKEDFS_KEYFILE or a tty)
#
# Settings live in /etc/dockedfs/client.conf (DOCKEDFS_CONFIG overrides the
# path); environment variables win over the file:
#   DOCKEDFS_AUTHKEY   the Tailscale auth key you gave the host (CHAP is derived from it)
#   DOCKEDFS_HOST      the host's tailnet IP
#   DOCKEDFS_PORT      iSCSI port                       (default 3260)
#   DOCKEDFS_IQN       target name (default iqn.2026-11.io.dockedfs:storage)
#   DOCKEDFS_NAME      device-mapper name               (default dockedfs)
#   DOCKEDFS_MOUNT     mount point                      (default /mnt/dockedfs)
#   DOCKEDFS_FS        filesystem for new disks         (default xfs)
#   DOCKEDFS_KEYFILE   LUKS key file; without one you type a passphrase
#   CHAP_USER, CHAP_PASSWORD   explicit login, if the host set one
#   CHAP_DISABLE=true  the host runs without CHAP
#   DOCKEDFS_ASSUME_YES=1  skip the "erase this disk?" confirmation
set -eu

SETTINGS="DOCKEDFS_AUTHKEY DOCKEDFS_HOST DOCKEDFS_PORT DOCKEDFS_IQN DOCKEDFS_NAME DOCKEDFS_MOUNT
DOCKEDFS_FS DOCKEDFS_KEYFILE DOCKEDFS_AUTOMOUNT DOCKEDFS_SETUP_DONE CHAP_USER CHAP_PASSWORD CHAP_DISABLE"

# ---------------------------------------------------------------- helpers ----
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B='' G='' Y='' R='' N=''; fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
good() { printf '%s  ✓ %s%s\n' "$G" "$*" "$N"; }
warn() { printf '%s  ! %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '%sdockedfs: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

# ask VAR "Question" [default]
ask() {
  local __v __d="${3:-}"
  if [ -n "$__d" ]; then printf '%s [%s]: ' "$2" "$__d"; else printf '%s: ' "$2"; fi
  IFS= read -r __v || die "no answer (stdin closed)"
  [ -n "$__v" ] || __v="$__d"
  printf -v "$1" '%s' "$__v"
}
# ask_secret VAR "Question"  (not echoed when typing on a terminal)
ask_secret() {
  local __v
  printf '%s: ' "$2"
  if [ -t 0 ]; then IFS= read -rs __v || die "no answer"; echo; else IFS= read -r __v || die "no answer (stdin closed)"; fi
  printf -v "$1" '%s' "$__v"
}
# yesno "Question" default(y|n)
yesno() {
  local a
  ask a "$1 (y/n)" "$2"
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ----------------------------------------------------------------- config ----
CONFIG="${DOCKEDFS_CONFIG:-/etc/dockedfs/client.conf}"
CONFDIR=$(dirname "$CONFIG")

load_config() {
  local k
  for k in $SETTINGS; do [ -n "${!k+x}" ] && eval "__env_$k=\${$k}"; done
  # shellcheck disable=SC1090
  [ -r "$CONFIG" ] && . "$CONFIG"
  for k in $SETTINGS; do v="__env_$k"; [ -n "${!v+x}" ] && printf -v "$k" '%s' "${!v}"; done
  return 0
}

# save KEY VALUE: persist one setting (file is root-only, it holds the auth key)
save() {
  mkdir -p "$CONFDIR"; chmod 700 "$CONFDIR"
  touch "$CONFIG"; chmod 600 "$CONFIG"
  local tmp; tmp=$(mktemp "$CONFDIR/.conf.XXXXXX")
  grep -v "^$1=" "$CONFIG" > "$tmp" || true
  printf "%s='%s'\n" "$1" "$2" >> "$tmp"
  mv "$tmp" "$CONFIG"; chmod 600 "$CONFIG"
  printf -v "$1" '%s' "$2"
}

apply_defaults() {
  PORT="${DOCKEDFS_PORT:-3260}"
  IQN="${DOCKEDFS_IQN:-iqn.2026-11.io.dockedfs:storage}"
  NAME="${DOCKEDFS_NAME:-dockedfs}"
  MNT="${DOCKEDFS_MOUNT:-/mnt/dockedfs}"
  FS="${DOCKEDFS_FS:-xfs}"
  KEYFILE="${DOCKEDFS_KEYFILE:-}"
  MAPPER="/dev/mapper/$NAME"
  BATCH=""; [ "${DOCKEDFS_ASSUME_YES:-0}" = 1 ] && BATCH="--batch-mode"
  if [ -z "${CHAP_USER:-}" ] && [ -n "${DOCKEDFS_AUTHKEY:-}" ]; then
    CHAP_USER=dockedfs
    CHAP_PASSWORD=$(printf %s "$DOCKEDFS_AUTHKEY" | sha256sum | cut -c1-16)
  fi
  HOST="${DOCKEDFS_HOST:-}"
  case "$HOST" in
    "" | *[!0-9.]*) [ -z "$HOST" ] || HOST=$(resolve_host "$HOST") ;;
  esac
  PORTAL="$HOST:$PORT"
  DISK="/dev/disk/by-path/ip-$PORTAL-iscsi-$IQN-lun-1"
}

resolve_host() {
  local ip=""
  if command -v tailscale >/dev/null 2>&1; then ip=$(tailscale ip -4 "$1" 2>/dev/null || true); fi
  [ -n "$ip" ] || ip=$(getent ahostsv4 "$1" | awk '{print $1; exit}' || true)
  [ -n "$ip" ] || die "cannot resolve host '$1'"
  echo "$ip"
}

need_chap() {
  [ -n "${CHAP_USER:-}" ] || [ "${CHAP_DISABLE:-false}" = true ] || \
    die "no login configured: run $0 with no arguments, or set DOCKEDFS_AUTHKEY"
}
need_host() { [ -n "$HOST" ] || die "no host configured: run $0 with no arguments, or set DOCKEDFS_HOST"; }

# ------------------------------------------------------------------ iSCSI ----
iscsi() { iscsiadm -m node -T "$IQN" -p "$PORTAL" "$@"; }
logged_in() { iscsiadm -m session 2>/dev/null | grep -q " $PORTAL,[0-9]* $IQN"; }

connect() {
  need_host; need_chap
  if logged_in; then return 0; fi
  # Add the node by IP rather than via sendtargets: the host runs Tailscale in
  # userspace mode, so discovery advertises an unreachable container address.
  iscsi >/dev/null 2>&1 || iscsi -o new >/dev/null
  if [ -n "${CHAP_USER:-}" ]; then
    iscsi -o update -n node.session.auth.authmethod -v CHAP
    iscsi -o update -n node.session.auth.username -v "$CHAP_USER"
    iscsi -o update -n node.session.auth.password -v "$CHAP_PASSWORD"
  else
    iscsi -o update -n node.session.auth.authmethod -v None
  fi
  local err
  if ! err=$(iscsi --login 2>&1 >/dev/null); then
    case "$err" in *[Aa]uth*)
      die "the host rejected the login. Check that the auth key is exactly the one in the host's .env." ;;
    esac
    printf '%s\n' "$err" >&2
    die "could not connect to $PORTAL. Is the host up, and does your tailnet ACL allow tcp:3260 to it?"
  fi
  local i=0
  until [ -b "$DISK" ]; do
    i=$((i + 1)); [ "$i" -gt 30 ] && die "logged in but $DISK never appeared"
    sleep 1
  done
}

# ------------------------------------------------------------------- LUKS ----
luks_key() { [ -n "$KEYFILE" ] && echo "--key-file=$KEYFILE" || true; }
unlock() {
  [ -b "$MAPPER" ] && return 0
  # shellcheck disable=SC2046
  cryptsetup open $(luks_key) "$DISK" "$NAME"
}

backup_header() {
  local hdr; hdr="$CONFDIR/luks-header-$(date +%Y%m%d-%H%M%S).img"
  cryptsetup luksHeaderBackup "$DISK" --header-backup-file "$hdr"
  chmod 400 "$hdr"
  HEADER_BACKUP="$hdr"
}

format_luks() {
  # shellcheck disable=SC2046
  cryptsetup luksFormat $BATCH -q --type luks2 --sector-size 4096 $(luks_key) "$DISK"
  backup_header
}

make_fs() {
  case "$FS" in
    xfs)  mkfs.xfs -q "$MAPPER" ;;
    ext4) mkfs.ext4 -q "$MAPPER" ;;
    *)    "mkfs.$FS" "$MAPPER" ;;
  esac
}

# --------------------------------------------------------- mount / umount ----
do_mount() {
  connect; unlock
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || mount "$MAPPER" "$MNT"
}

do_umount() {
  if mountpoint -q "$MNT"; then umount "$MNT"; fi
  if [ -b "$MAPPER" ]; then
    # Right after an unmount the device can be briefly busy (udev, flushes); retry.
    local i=0
    command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true
    until cryptsetup close "$NAME" 2>/dev/null; do
      i=$((i + 1)); [ "$i" -ge 10 ] && { cryptsetup close "$NAME"; break; }
      sleep 1
    done
  fi
  if [ -n "$HOST" ] && logged_in; then iscsi --logout >/dev/null; fi
  return 0
}

grow() {
  logged_in || die "not connected"
  iscsiadm -m session --rescan >/dev/null
  # shellcheck disable=SC2046
  cryptsetup resize $(luks_key) "$NAME"
  case "$(findmnt -no FSTYPE "$MNT")" in
    xfs)  xfs_growfs "$MNT" >/dev/null ;;
    ext4) resize2fs "$MAPPER" >/dev/null ;;
    *)    die "grow your filesystem on $MAPPER manually" ;;
  esac
  df -h "$MNT"
}

status() {
  say "host:    ${HOST:-not set} (port $PORT)"
  if [ -n "$HOST" ] && logged_in; then say "session: connected"; else say "session: not connected"; fi
  if [ -b "$MAPPER" ]; then say "disk:    unlocked"; else say "disk:    locked"; fi
  if mountpoint -q "$MNT"; then
    df -h "$MNT" | awk 'NR==2 {print "mount:   "$6" ("$3" used of "$2", "$4" free)"}'
  else say "mount:   not mounted ($MNT)"; fi
  if [ "${DOCKEDFS_AUTOMOUNT:-no}" = yes ]; then say "boot:    mounts automatically"; else say "boot:    run 'sudo dockedfs-client mount' after a reboot"; fi
}

# ----------------------------------------------------------- guided setup ----
wizard_deps() {
  local missing=""
  command -v iscsiadm   >/dev/null 2>&1 || missing="$missing open-iscsi"
  command -v cryptsetup >/dev/null 2>&1 || missing="$missing cryptsetup"
  command -v mkfs.xfs   >/dev/null 2>&1 || missing="$missing xfsprogs"
  if [ -n "$missing" ]; then
    step "Installing tools"
    command -v apt-get >/dev/null 2>&1 || die "please install:$missing"
    yesno "Install$missing with apt-get?" y || die "these are required:$missing"
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing >/dev/null
    good "installed$missing"
  fi
  if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active -q iscsid 2>/dev/null; then
    systemctl start iscsid 2>/dev/null || true
  fi
}

wizard_authkey() {
  [ -z "${CHAP_USER:-}" ] || return 0
  [ "${CHAP_DISABLE:-false}" != true ] || return 0
  step "Auth key"
  say "Paste the Tailscale auth key you gave your friend for their DockedFS host."
  say "The iSCSI login is derived from it, so nobody else on your tailnet can attach your disk."
  local k
  while :; do
    ask_secret k "Auth key"
    case "$k" in tskey-auth-*) break ;; *) warn "that doesn't look like an auth key (it starts with tskey-auth-)" ;; esac
  done
  save DOCKEDFS_AUTHKEY "$k"
  good "saved to $CONFIG (readable by root only)"
}

list_dockedfs_peers() {
  command -v tailscale >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 0
  tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for p in (d.get("Peer") or {}).values():
    if "tag:dockedfs" in (p.get("Tags") or []):
        ip = next((a for a in p.get("TailscaleIPs", []) if "." in a), "")
        name = (p.get("DNSName") or p.get("HostName") or "").rstrip(".")
        print(ip, name, "online" if p.get("Online") else "offline", sep="\t")
' || true
}

wizard_host() {
  [ -z "${DOCKEDFS_HOST:-}" ] || return 0
  step "Pick your friend's DockedFS host"
  if ! command -v tailscale >/dev/null 2>&1; then
    warn "Tailscale isn't installed. Install it with: curl -fsSL https://tailscale.com/install.sh | sh"
  elif ! tailscale status >/dev/null 2>&1; then
    warn "Tailscale isn't connected. Run 'sudo tailscale up' first."
  fi
  local peers n choice ip
  peers=$(list_dockedfs_peers)
  n=$(printf '%s' "$peers" | grep -c . || true)
  if [ "$n" -gt 0 ]; then
    say "DockedFS hosts on your tailnet (devices tagged tag:dockedfs):"
    printf '%s\n' "$peers" | awk -F'\t' '{printf "  %d) %-40s %-16s %s\n", NR, $2, $1, $3}'
    while :; do
      ask choice "Which one" 1
      [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$n" ] && break
      warn "pick a number from 1 to $n"
    done
    ip=$(printf '%s\n' "$peers" | sed -n "${choice}p" | cut -f1)
  else
    say "No devices tagged tag:dockedfs are visible. Either your friend's host isn't running"
    say "yet, or the auth key you made didn't have the tag (see the README)."
    ask ip "Enter the host's tailnet IP or name instead"
    [ -n "$ip" ] || die "no host given"
    ip=$(resolve_host "$ip")
  fi
  save DOCKEDFS_HOST "$ip"
  good "using $ip"
}

wizard_connect() {
  if logged_in; then return 0; fi
  step "Connecting to $PORTAL"
  connect
  good "connected ($(lsblk -dno SIZE "$(readlink -f "$DISK")" | tr -d ' ') disk)"
}

# Choose and remember how the disk is unlocked. Sets KEYFILE when a key file is used.
wizard_new_key() {
  local c k
  say "How do you want to unlock it?"
  say "  1) Generate a strong random key and keep it in a key file on this machine (recommended)."
  say "     The disk can then mount by itself at boot."
  say "  2) Type my own passphrase each time I mount it."
  ask c "Choice" 1
  if [ "$c" = 2 ]; then
    while :; do
      ask_secret k "New passphrase (at least 12 characters)"
      [ "${#k}" -ge 12 ] || { warn "too short"; continue; }
      ask_secret c "Repeat it"
      [ "$k" = "$c" ] && break
      warn "they don't match"
    done
    KEYFILE=$(mktemp "$CONFDIR/.pass.XXXXXX"); printf %s "$k" > "$KEYFILE"
    TEMP_KEYFILE=1
  else
    KEYFILE="$CONFDIR/$NAME.key"
    tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 48 > "$KEYFILE" || true
    chmod 400 "$KEYFILE"
    GENERATED_KEY=1
    save DOCKEDFS_KEYFILE "$KEYFILE"
  fi
}

wizard_luks() {
  [ -b "$MAPPER" ] && return 0
  if cryptsetup isLuks "$DISK"; then
    if [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ]; then
      unlock; good "unlocked with $KEYFILE"; return 0
    fi
    step "Unlock your encrypted disk"
    say "This disk is already encrypted."
    if yesno "Save the key in a key file here, so it can mount by itself at boot?" n; then
      local k
      ask_secret k "Passphrase or key"
      KEYFILE="$CONFDIR/$NAME.key"; printf %s "$k" > "$KEYFILE"; chmod 400 "$KEYFILE"
      cryptsetup open --test-passphrase --key-file="$KEYFILE" "$DISK" || { rm -f "$KEYFILE"; die "that key doesn't unlock the disk"; }
      save DOCKEDFS_KEYFILE "$KEYFILE"
    fi
    unlock; good "unlocked"
    return 0
  fi

  step "Encrypt the disk"
  say "The remote disk is blank. It will be encrypted with LUKS2 on this machine."
  say "Your friend only ever stores the encrypted result."
  if [ "${DOCKEDFS_ASSUME_YES:-0}" != 1 ]; then
    local a
    ask a "This erases anything on the remote disk. Type 'yes' to continue"
    [ "$a" = yes ] || die "stopped; nothing was changed"
  fi
  wizard_new_key
  BATCH="--batch-mode"
  format_luks
  unlock
  [ -z "${TEMP_KEYFILE:-}" ] || { rm -f "$KEYFILE"; KEYFILE=""; }
  good "encrypted and unlocked"
}

wizard_fs() {
  local t; t=$(blkid -o value -s TYPE "$MAPPER" 2>/dev/null || true)
  if [ -n "$t" ]; then FS="$t"; return 0; fi
  step "Create a filesystem"
  local f
  ask f "Filesystem (xfs or ext4)" "$FS"
  case "$f" in xfs|ext4) ;; *) die "pick xfs or ext4" ;; esac
  FS="$f"; save DOCKEDFS_FS "$FS"
  make_fs
  NEW_FS=1
  good "$FS created"
}

wizard_mount() {
  if [ -z "${DOCKEDFS_MOUNT:-}" ]; then
    step "Choose where to mount it"
    local m
    ask m "Mount point" "$MNT"
    case "$m" in /*) ;; *) die "use an absolute path" ;; esac
    MNT="$m"; save DOCKEDFS_MOUNT "$MNT"
  fi
  if ! mountpoint -q "$MNT"; then
    mkdir -p "$MNT"
    mount "$MAPPER" "$MNT"
  fi
  if [ -n "${NEW_FS:-}" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    chown "$SUDO_USER:" "$MNT"
    good "mounted at $MNT (owned by $SUDO_USER, so you can write without sudo)"
  else
    good "mounted at $MNT"
  fi
}

install_unit() {
  install -m 755 "$(readlink -f "$0")" /usr/local/sbin/dockedfs-client
  cat > /etc/systemd/system/dockedfs.service <<EOF
[Unit]
Description=DockedFS remote encrypted disk ($MNT)
Wants=network-online.target tailscaled.service
After=network-online.target tailscaled.service iscsid.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=DOCKEDFS_CONFIG=$CONFIG
ExecStart=/usr/local/sbin/dockedfs-client mount
ExecStop=/usr/local/sbin/dockedfs-client umount
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q dockedfs.service
}

wizard_boot() {
  [ -z "${DOCKEDFS_AUTOMOUNT:-}" ] || return 0
  command -v systemctl >/dev/null 2>&1 || { save DOCKEDFS_AUTOMOUNT no; return 0; }
  step "Mount at boot"
  if [ -z "$KEYFILE" ]; then
    say "You unlock with a passphrase, so it can't mount by itself at boot."
    say "After a reboot, run: sudo dockedfs-client mount"
    install -m 755 "$(readlink -f "$0")" /usr/local/sbin/dockedfs-client
    save DOCKEDFS_AUTOMOUNT no
    return 0
  fi
  if yesno "Mount $MNT automatically at boot (retries until your friend's host is reachable)?" y; then
    install_unit
    save DOCKEDFS_AUTOMOUNT yes
    good "enabled dockedfs.service"
  else
    install -m 755 "$(readlink -f "$0")" /usr/local/sbin/dockedfs-client
    save DOCKEDFS_AUTOMOUNT no
    say "After a reboot, run: sudo dockedfs-client mount"
  fi
}

wizard_reminder() {
  [ -z "${DOCKEDFS_SETUP_DONE:-}" ] || return 0
  step "Back up your keys. Do this now."
  say "If this machine dies, these are the only way back to your data. Put them in a password"
  say "manager (1Password, Bitwarden, KeePassXC...) or somewhere else that isn't this machine:"
  say ""
  say "  ${B}1. Tailscale auth key${N}: lets you log in to the disk from a new machine."
  [ -z "${DOCKEDFS_AUTHKEY:-}" ] || say "     $DOCKEDFS_AUTHKEY"
  if [ -n "${GENERATED_KEY:-}" ]; then
    say "  ${B}2. Encryption key${N}: unlocks your data. Without it, the data is gone for good."
    say "     $(cat "$KEYFILE")"
  elif [ -n "$KEYFILE" ]; then
    say "  ${B}2. Encryption key${N}: the contents of $KEYFILE."
  else
    say "  ${B}2. Encryption passphrase${N}: the one you just typed. Without it, the data is gone for good."
  fi
  if [ -n "${HEADER_BACKUP:-}" ]; then
    say "  ${B}3. LUKS header backup${N}: $HEADER_BACKUP"
    say "     If the start of the remote disk is damaged, this plus your key recovers the data."
  fi
  say ""
  if [ "${DOCKEDFS_ASSUME_YES:-0}" != 1 ]; then
    local a; ask a "Press Enter once you've saved them" ""
  fi
  save DOCKEDFS_SETUP_DONE yes
}

wizard() {
  say "${B}DockedFS client setup${N}  (settings: $CONFIG)"
  wizard_deps
  wizard_authkey; apply_defaults
  wizard_host;    apply_defaults
  wizard_connect
  wizard_luks
  wizard_fs
  wizard_mount
  wizard_boot
  wizard_reminder
  step "All set"
  status
  say ""
  say "Back up to $MNT with rsync, restic, Borg, Duplicati or plain cp."
}

# ------------------------------------------------------------------- main ----
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "run as root"
  exec sudo DOCKEDFS_CONFIG="$CONFIG" "$0" "$@"
fi

mkdir -p "$CONFDIR" && chmod 700 "$CONFDIR"
load_config
apply_defaults

case "${1:-}" in
  "")         wizard ;;
  mount)      do_mount; say "mounted at $MNT" ;;
  umount|unmount|disconnect) do_umount; say "disconnected" ;;
  status)     status ;;
  grow)       grow ;;
  connect)    connect; say "connected: $DISK" ;;
  init)       connect
              cryptsetup isLuks "$DISK" && die "$DISK already holds a LUKS volume; refusing to overwrite it"
              format_luks; unlock; make_fs; do_mount
              say "initialized and mounted at $MNT; LUKS header backup: $HEADER_BACKUP" ;;
  chap)       need_chap; say "CHAP_USER=${CHAP_USER:-}"; say "CHAP_PASSWORD=${CHAP_PASSWORD:-}" ;;
  -h|--help|help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)          die "unknown command '$1' (try --help)" ;;
esac
