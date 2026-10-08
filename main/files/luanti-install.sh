#!/bin/bash
# Install or refresh the Luanti game, image, and systemd units.
# Safe to re-run. Does not delete an existing world.
set -euo pipefail

GAME_ID="${GAME_ID:-}"
GAME_GIT_URL="${GAME_GIT_URL:-}"
GAME_GIT_REF="${GAME_GIT_REF:-}"
WORLD_NAME="${WORLD_NAME:-}"
LUANTI_IMAGE="${LUANTI_IMAGE:-}"
BACKUP_UPLOAD="${BACKUP_UPLOAD:-false}"

# shellcheck disable=SC1091
source /etc/luanti/server.env

: "${GAME_ID:?GAME_ID missing}"
: "${GAME_GIT_URL:?GAME_GIT_URL missing}"
: "${GAME_GIT_REF:?GAME_GIT_REF missing}"
: "${WORLD_NAME:?WORLD_NAME missing}"
: "${LUANTI_IMAGE:?LUANTI_IMAGE missing}"

exec 9>/var/lock/luanti-admin.lock
flock 9

retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if "$@"; then
      return 0
    fi
    echo "command failed (attempt ${attempt}): $*" >&2
    sleep $((attempt * 5))
  done
  return 1
}

install -d -m 0755 \
  /var/lib/luanti/data/.minetest/games \
  /var/lib/luanti/data/.minetest/worlds \
  "/var/lib/luanti/data/.minetest/worlds/${WORLD_NAME}/worldmods/player_allowlist" \
  /var/lib/luanti/backups \
  /var/lib/luanti/password-drop

game_dir="/var/lib/luanti/data/.minetest/games/${GAME_ID}"
pin_file="${game_dir}/.pinned-ref"
if [[ ! -f "$pin_file" ]] || [[ "$(cat "$pin_file")" != "$GAME_GIT_REF" ]]; then
  rm -rf "$game_dir"
  mkdir -p "$game_dir"
  git -C "$game_dir" init
  git -C "$game_dir" remote add origin "$GAME_GIT_URL"
  retry git -C "$game_dir" fetch --depth 1 origin "$GAME_GIT_REF"
  git -C "$game_dir" checkout --detach FETCH_HEAD
  if [[ -f "${game_dir}/.gitmodules" ]]; then
    git -C "$game_dir" submodule update --init --recursive --depth 1
  fi
  printf '%s\n' "$GAME_GIT_REF" >"$pin_file"
fi

if [[ "$BACKUP_UPLOAD" == "true" ]] && grep -q 'FROM_BOOTSTRAP_OUTPUT' /etc/luanti/rclone.conf; then
  echo "rclone.conf still contains placeholder credentials" >&2
  exit 1
fi

retry docker pull "$LUANTI_IMAGE"

chown -R 30000:30000 /var/lib/luanti/data /var/lib/luanti/password-drop
chmod 0700 /var/lib/luanti/password-drop

systemctl daemon-reload
systemctl enable luanti.service
systemctl enable luanti-backup.timer
systemctl restart luanti.service
systemctl restart luanti-backup.timer || systemctl start luanti-backup.timer

ready=0
logs=""
for _ in $(seq 1 30); do
  logs="$(docker logs luanti 2>&1 || true)"
  if grep -F -q '[player_allowlist] loaded' <<<"$logs"; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "$ready" != "1" ]]; then
  echo "Luanti did not log the allowlist mod. Recent logs:" >&2
  printf '%s\n' "$logs" | tail -n 80 >&2 || true
  systemctl status luanti.service --no-pager >&2 || true
  exit 1
fi

# actionstream logs "Announcing start to <url>" only when server_announce is true.
if grep -F -e 'Announcing start to' -e 'Announcing update to' <<<"$logs" >/dev/null; then
  echo "Luanti is announcing to the public server list. Refusing to leave it running." >&2
  printf '%s\n' "$logs" | tail -n 80 >&2 || true
  exit 1
fi

echo "luanti-install: server is up and the allowlist mod loaded"
