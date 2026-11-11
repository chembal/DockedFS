#!/bin/sh
# Update a DockedFS host: newest code, newest Tailscale image, and a fresh
# iSCSI server image with the latest Ubuntu security fixes. Your .env, the
# disk image in DATA_DIR and Tailscale's login are kept.
#
# Usage: ./update.sh
set -eu
cd "$(dirname "$0")"

if [ -t 1 ]; then B=$(printf '\033[1m'); G=$(printf '\033[32m'); R=$(printf '\033[31m'); N=$(printf '\033[0m'); else B='' G='' R='' N=''; fi
total=5
n=0
step() { n=$((n + 1)); printf '\n%s[%d/%d] %s%s\n' "$B" "$n" "$total" "$1" "$N"; shift; printf '      $ %s\n' "$*"; "$@"; }
die() { trap - EXIT; printf '\n%sUpdate stopped: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
trap 'die "the step above failed. Nothing after it was run, and your current setup is still the one running."' EXIT

[ -f .env ] || { die "no .env here. Run this from your DockedFS folder after setup (cp .env.example .env)."; }
command -v docker >/dev/null 2>&1 || { die "docker isn't installed or isn't on PATH."; }

step "Getting the latest DockedFS code" git pull --ff-only
step "Downloading the latest Tailscale image" docker compose pull --ignore-buildable
step "Rebuilding the iSCSI server image with the latest Ubuntu updates" docker compose build --pull
before=$(docker compose ps -q target 2>/dev/null || true)
since=$(date +%s)
step "Restarting with the new images (your data and Tailscale login are kept)" docker compose up -d --remove-orphans
after=$(docker compose ps -q target 2>/dev/null || true)

n=$((n + 1)); printf '\n%s[%d/%d] Waiting for the iSCSI server to come back%s\n' "$B" "$n" "$total" "$N"
if [ -n "$before" ] && [ "$before" = "$after" ]; then
  # Nothing changed, so nothing was restarted; look at its last start instead.
  since=$(docker inspect -f '{{.State.StartedAt}}' "$after")
fi
i=0
until docker compose logs --since "$since" target 2>/dev/null | grep -q '\[dockedfs\] Ready'; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    docker compose logs --tail 20 target || true
    die "the server didn't report Ready within 2 minutes. Its last log lines are above."
  fi
  sleep 2
done
trap - EXIT

docker compose logs --since "$since" target 2>/dev/null | grep '\[dockedfs\]' | sed 's/^[^|]*| /      /'
printf '\n%sUpdate complete.%s\n' "$G" "$N"
docker compose ps --format '      {{.Name}}: {{.Status}}' 2>/dev/null || docker compose ps
