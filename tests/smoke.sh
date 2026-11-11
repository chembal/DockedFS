#!/bin/sh
# End-to-end smoke test for the DockedFS target.
#
#   ./tests/smoke.sh            protocol tests with a userspace iSCSI client (no root)
#   sudo -E ./tests/smoke.sh    also runs the real client: iscsiadm, LUKS, xfs, mount, grow
set -eu
cd "$(dirname "$0")"

PORT="${TEST_PORT:-13260}"
IQN=iqn.2026-11.io.dockedfs:storage
TEST_DATA_DIR="$(mktemp -d)"
# Client-side files live outside the host data dir: that dir is bind-mounted into
# the target container, which would otherwise pin any filesystem mounted inside it.
CLIENT_DIR="$(mktemp -d)"
export TEST_PORT="$PORT" TEST_DATA_DIR STORAGE_SIZE=1G
COMPOSE="docker compose -f docker-compose.test.yml"
URL="iscsi://tester%smoke-test-123@127.0.0.1:$PORT/$IQN/1"
CLIENT_IMG=dockedfs-testclient

pass=0
ok()   { pass=$((pass + 1)); echo "  ok   $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }

cleanup() {
  set +e
  if [ "$(id -u)" -eq 0 ]; then
    for conf in client.conf wizard.conf; do
      DOCKEDFS_CONFIG="$CLIENT_DIR/conf/$conf" DOCKEDFS_HOST=127.0.0.1 DOCKEDFS_PORT=$PORT \
        DOCKEDFS_AUTHKEY=x DOCKEDFS_MOUNT="$CLIENT_DIR/mnt" timeout 60 ../client/dockedfs-client.sh umount </dev/null >/dev/null 2>&1
    done
    iscsiadm -m node -T "$IQN" -p "127.0.0.1:$PORT" -o delete >/dev/null 2>&1
  fi
  $COMPOSE down -v >/dev/null 2>&1
  docker run --rm -v "$TEST_DATA_DIR:/d" alpine rm -rf /d/disk.img >/dev/null 2>&1
  rm -rf "$TEST_DATA_DIR" "$CLIENT_DIR"
}
trap cleanup EXIT

wait_ready() {
  i=0
  until docker logs --since "${1:-0}" dockedfs-test-target 2>&1 | grep -q "\[dockedfs\] Ready"; do
    i=$((i + 1)); [ "$i" -gt 60 ] && { docker logs dockedfs-test-target; fail "target never became ready"; }
    sleep 1
  done
}
uclient() { docker run --rm --network host "$CLIENT_IMG" "$@" 2>/dev/null; }

echo "== building images"
timeout 600 $COMPOSE build --progress plain > "$TEST_DATA_DIR/build.log" 2>&1 || { tail -40 "$TEST_DATA_DIR/build.log"; fail "image build"; }
timeout 600 docker build -q --build-arg UBUNTU_MIRROR="${UBUNTU_MIRROR:-}" -t "$CLIENT_IMG" - >/dev/null <<'EOF' || fail "test client build"
FROM ubuntu:latest
ARG UBUNTU_MIRROR=
RUN if [ -n "$UBUNTU_MIRROR" ]; then sed -i "s#http://archive.ubuntu.com/ubuntu#$UBUNTU_MIRROR#g; s#http://security.ubuntu.com/ubuntu#$UBUNTU_MIRROR#g" /etc/apt/sources.list.d/ubuntu.sources; fi \
 && apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 update \
 && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
    libiscsi-bin qemu-utils qemu-block-extra && rm -rf /var/lib/apt/lists/*
EOF

echo "== target"
$COMPOSE up -d >/dev/null 2>&1
wait_ready
ok "target starts"

size=$(stat -c %s "$TEST_DATA_DIR/disk.img")
[ "$size" -eq 1073741824 ] || fail "image size $size"
[ "$(du -k "$TEST_DATA_DIR/disk.img" | cut -f1)" -lt 1024 ] || fail "image is not sparse"
ok "1G image created sparse"

echo "== firewall (no LAN access, tgt has no network)"
reach() { # reach <user> <ip> <port>: exit 0 if a TCP connect succeeds from inside the target
  if [ "$1" = tgt ]; then
    docker exec dockedfs-test-target setpriv --reuid tgt --regid tgt --init-groups timeout 5 bash -c "</dev/tcp/$2/$3" 2>/dev/null
  else
    docker exec dockedfs-test-target timeout 5 bash -c "</dev/tcp/$2/$3" 2>/dev/null
  fi
}
GW=$(docker exec dockedfs-test-target ip -4 route show default | awk '{print $3; exit}')
for dst in "$GW 53" "$GW 22" "192.168.1.1 80" "10.0.0.1 443" "172.17.0.1 2375" "169.254.169.254 80"; do
  # shellcheck disable=SC2086
  reach root $dst && fail "container reached private address $dst"
done
ok "private/LAN addresses unreachable (gateway, 192.168/16, 10/8, docker host, cloud metadata)"
if timeout 5 bash -c "</dev/tcp/1.1.1.1/443" 2>/dev/null; then
  reach root 1.1.1.1 443 || fail "Tailscale's HTTPS egress is blocked"
  reach root 1.1.1.1 22 && fail "non-Tailscale port reachable on the internet"
  reach tgt 1.1.1.1 443 && fail "the tgt user reached the internet"
  ok "internet: HTTPS allowed for Tailscale, other ports blocked, tgt user blocked entirely"
else
  echo "  skip internet checks (this machine has no internet access)"
fi

echo "== protocol (userspace client)"
uclient iscsi-inq "iscsi://127.0.0.1:$PORT/$IQN/1" >/dev/null 2>&1 && fail "login without CHAP succeeded"
ok "login without CHAP rejected"
uclient iscsi-inq "iscsi://tester%wrong-password1@127.0.0.1:$PORT/$IQN/1" >/dev/null 2>&1 && fail "wrong password accepted"
ok "wrong CHAP password rejected"
uclient qemu-io -f raw -c "write -P 0x5a 0 64M" "$URL" | grep -q "wrote 67108864" || fail "write"
uclient qemu-io -f raw -c "read -P 0x5a 0 64M" "$URL" | grep -q "read 67108864" || fail "read-back"
ok "64M write and verified read"

t=$(date +%s); docker restart dockedfs-test-target >/dev/null; wait_ready "$t"
uclient qemu-io -f raw -c "read -P 0x5a 0 64M" "$URL" | grep -q "read 67108864" || fail "data lost on restart"
ok "data survives restart"

echo "== size changes"
STORAGE_SIZE=512M $COMPOSE run --rm --no-deps -T target 2>&1 | grep -q "Refusing to shrink" || fail "shrink not refused"
[ "$(stat -c %s "$TEST_DATA_DIR/disk.img")" -eq 1073741824 ] || fail "image was shrunk"
ok "shrinking refused, image untouched"

echo "== default mode: CHAP login derived from the Tailscale auth key"
TEST_AUTHKEY=tskey-auth-smoketest-0123456789abcdef
DERIVED_PW=$(printf %s "$TEST_AUTHKEY" | sha256sum | cut -c1-16)
DERIVED_USER=$(printf %s "$TEST_AUTHKEY" | sha256sum | cut -c17-32)
export TEST_AUTHKEY TEST_CHAP_USER="" TEST_CHAP_PASSWORD=""
t=$(date +%s); $COMPOSE up -d >/dev/null 2>&1; wait_ready "$t"
docker logs --since "$t" dockedfs-test-target 2>&1 | grep -q "derived from TS_AUTHKEY" || fail "target did not derive CHAP"
uclient iscsi-inq "iscsi://127.0.0.1:$PORT/$IQN/1" >/dev/null 2>&1 && fail "derived mode allowed login without CHAP"
uclient qemu-io -f raw -c "read -P 0x5a 0 64M" "iscsi://$DERIVED_USER%$DERIVED_PW@127.0.0.1:$PORT/$IQN/1" | grep -q "read 67108864" \
  || fail "derived CHAP login failed"
uclient iscsi-inq "iscsi://dockedfs%$DERIVED_PW@127.0.0.1:$PORT/$IQN/1" >/dev/null 2>&1 && fail "old fixed username still accepted"
ok "derived CHAP: key holder logs in, others rejected"
TEST_AUTHKEY="" $COMPOSE run --rm --no-deps -T target 2>&1 | grep -q "TS_AUTHKEY is needed" || fail "missing key not reported"
ok "refuses to run open when the key is missing"
TEST_CHAP_USER=onlyuser $COMPOSE run --rm --no-deps -T target 2>&1 | grep -q "set both CHAP_USER and CHAP_PASSWORD" \
  || fail "half-configured CHAP not rejected"
ok "half-configured CHAP refused"

echo "== CHAP_DISABLE=true"
t=$(date +%s); TEST_CHAP_DISABLE=true $COMPOSE up -d >/dev/null 2>&1; wait_ready "$t"
uclient qemu-io -f raw -c "read -P 0x5a 0 64M" "iscsi://127.0.0.1:$PORT/$IQN/1" | grep -q "read 67108864" \
  || fail "open login failed with CHAP disabled"
ok "CHAP disabled: open login, same data"
t=$(date +%s); $COMPOSE up -d >/dev/null 2>&1; wait_ready "$t"   # back to derived mode

if [ "$(id -u)" -ne 0 ] || ! command -v iscsiadm >/dev/null 2>&1; then
  echo "== skipping kernel client tests (run with sudo -E and open-iscsi installed)"
  echo "PASS ($pass checks)"
  exit 0
fi

echo "== real client (iscsiadm + LUKS + xfs, derived CHAP)"
KEY="$CLIENT_DIR/luks.key"; head -c 64 /dev/urandom > "$KEY"
unset CHAP_USER CHAP_PASSWORD
export DOCKEDFS_AUTHKEY="$TEST_AUTHKEY" DOCKEDFS_CONFIG="$CLIENT_DIR/conf/client.conf"
export DOCKEDFS_HOST=127.0.0.1 DOCKEDFS_PORT=$PORT \
       DOCKEDFS_KEYFILE="$KEY" DOCKEDFS_ASSUME_YES=1 DOCKEDFS_MOUNT="$CLIENT_DIR/mnt"
CLI="$(pwd)/../client/dockedfs-client.sh"
# Every client call gets a time limit, so a hang fails loudly instead of stalling CI.
client() { echo "    \$ dockedfs-client $*" >&2; timeout 240 "$CLI" "$@"; }
client init </dev/null >/dev/null || fail "client init"
ok "client init (LUKS2 + xfs + mount)"

head -c 32M /dev/urandom > "$CLIENT_DIR/payload"
cp "$CLIENT_DIR/payload" "$DOCKEDFS_MOUNT/"
sum=$(sha256sum < "$CLIENT_DIR/payload")
client umount </dev/null >/dev/null || fail "umount"
ok "write 32M, unmount and log out"

python3 - "$CLIENT_DIR/payload" "$TEST_DATA_DIR/disk.img" <<'PY' || fail "plaintext visible on host"
import sys
needle = open(sys.argv[1], "rb").read(1 << 20)[4096:8192]
sys.exit(1 if needle in open(sys.argv[2], "rb").read() else 0)
PY
cryptsetup isLuks "$TEST_DATA_DIR/disk.img" || fail "host image is not LUKS"
ok "host only holds a LUKS volume"

client mount </dev/null >/dev/null || fail "remount"
[ "$(sha256sum < "$DOCKEDFS_MOUNT/payload")" = "$sum" ] || fail "checksum mismatch after remount"
ok "remount and checksum matches"

t=$(date +%s); STORAGE_SIZE=2G $COMPOSE up -d >/dev/null 2>&1; wait_ready "$t"
# The restarted target drops the session; give the initiator a moment to recover.
i=0; until iscsiadm -m session -P 3 2>/dev/null | grep -q "Session State: LOGGED_IN"; do
  i=$((i + 1)); [ "$i" -gt 30 ] && fail "session did not recover after target restart"; sleep 1
done
client grow </dev/null >/dev/null || fail "grow"
fs_bytes=$(df -B1 --output=size "$DOCKEDFS_MOUNT" | tail -1)
[ "$fs_bytes" -gt 1500000000 ] || fail "filesystem did not grow ($fs_bytes)"
[ "$(sha256sum < "$DOCKEDFS_MOUNT/payload")" = "$sum" ] || fail "data damaged by grow"
ok "grow 1G -> 2G online, data intact"

echo "== guided setup (./dockedfs-client.sh with no arguments)"
if ! client umount </dev/null >/dev/null; then
  echo "--- diagnostics"; findmnt -S /dev/mapper/dockedfs || true; dmsetup info dockedfs || true
  for h in /sys/block/*/holders/*; do [ -e "$h" ] && echo "$h"; done
  grep dockedfs /proc/*/mountinfo 2>/dev/null | cut -d: -f1 | sort -u | head || true
  fuser -vm /dev/mapper/dockedfs 2>&1 || true; lsblk || true
  fail "umount before wizard test"
fi
iscsiadm -m node -T "$IQN" -p "127.0.0.1:$PORT" -o delete >/dev/null 2>&1 || true
$COMPOSE down >/dev/null 2>&1
docker run --rm -v "$TEST_DATA_DIR:/d" alpine rm -f /d/disk.img
t=$(date +%s); $COMPOSE up -d >/dev/null 2>&1; wait_ready "$t"   # a fresh, blank disk
unset DOCKEDFS_AUTHKEY DOCKEDFS_HOST DOCKEDFS_KEYFILE DOCKEDFS_ASSUME_YES DOCKEDFS_MOUNT
export DOCKEDFS_CONFIG="$CLIENT_DIR/conf/wizard.conf"
WMNT="$CLIENT_DIR/wizard-mnt"
# Answers, in order: auth key, host (no tailscale on CI, so typed in), erase
# confirmation, key choice (generate), filesystem (default), mount point,
# mount at boot (no), "press Enter once you've saved the keys".
printf '%s\n' "$TEST_AUTHKEY" 127.0.0.1 yes 1 "" "$WMNT" n "" | client > "$CLIENT_DIR/wizard.log" 2>&1 \
  || { cat "$CLIENT_DIR/wizard.log"; fail "guided setup"; }
mountpoint -q "$WMNT" || { cat "$CLIENT_DIR/wizard.log"; fail "guided setup did not mount"; }
grep -q "^DOCKEDFS_SETUP_DONE='yes'" "$DOCKEDFS_CONFIG" || fail "setup not recorded"
[ "$(stat -c %a "$DOCKEDFS_CONFIG")" = 600 ] || fail "config is not root-only"
kf="$CLIENT_DIR/conf/dockedfs.key"
[ "$(stat -c %a "$kf")" = 400 ] || fail "key file permissions"
grep -qF "$(cat "$kf")" "$CLIENT_DIR/wizard.log" || fail "generated key not shown in the backup reminder"
grep -q "LUKS header backup" "$CLIENT_DIR/wizard.log" || fail "header backup not mentioned"
ok "guided setup: key entry, host, LUKS with generated key, xfs, mount, key reminder"

echo hello > "$WMNT/file"
client </dev/null > "$CLIENT_DIR/wizard2.log" 2>&1 || { cat "$CLIENT_DIR/wizard2.log"; fail "second run"; }
grep -q "All set" "$CLIENT_DIR/wizard2.log" || fail "second run did not finish"
grep -q "Back up your keys" "$CLIENT_DIR/wizard2.log" && fail "second run repeated the key reminder"
ok "re-running asks nothing and just shows status"

client umount </dev/null >/dev/null || fail "umount after wizard"
mountpoint -q "$WMNT" && fail "still mounted"
client </dev/null > "$CLIENT_DIR/wizard3.log" 2>&1 || { cat "$CLIENT_DIR/wizard3.log"; fail "remount via wizard"; }
[ "$(cat "$WMNT/file")" = hello ] || fail "data lost across wizard remount"
ok "after unmount, re-running reconnects and remounts with the key file"

echo "PASS ($pass checks)"
