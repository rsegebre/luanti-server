#!/bin/bash
# Stop the server, tar the world, rotate copies, optionally upload.
# Brief downtime is intentional so the sqlite files are consistent.
set -euo pipefail

WORLD_NAME="${WORLD_NAME:-}"
BACKUP_UPLOAD="${BACKUP_UPLOAD:-false}"
BACKUP_RETENTION="${BACKUP_RETENTION:-7}"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"

# shellcheck disable=SC1091
source /etc/luanti/server.env

: "${WORLD_NAME:?WORLD_NAME missing}"
: "${BACKUP_RETENTION:?BACKUP_RETENTION missing}"

exec 9>/var/lock/luanti-admin.lock
flock 9

world_dir="/var/lib/luanti/data/.minetest/worlds/${WORLD_NAME}"
if [[ ! -d "$world_dir" ]]; then
  echo "world directory not found: $world_dir" >&2
  exit 1
fi

install -d -m 0755 /var/lib/luanti/backups
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="/var/lib/luanti/backups/world-${stamp}.tar.gz"

systemctl stop luanti.service
trap 'systemctl start luanti.service || true' EXIT

tar -C /var/lib/luanti/data/.minetest/worlds -czf "$dest" "$WORLD_NAME"
echo "wrote ${dest}"

shopt -s nullglob
archives=(/var/lib/luanti/backups/world-*.tar.gz)
shopt -u nullglob
if ((${#archives[@]} > BACKUP_RETENTION)); then
  mapfile -t sorted < <(printf '%s\n' "${archives[@]}" | sort -r)
  for old in "${sorted[@]:BACKUP_RETENTION}"; do
    rm -f "$old"
  done
fi

if [[ "$BACKUP_UPLOAD" == "true" ]]; then
  : "${BACKUP_BUCKET:?BACKUP_BUCKET missing}"
  rclone copy "$dest" "linode:${BACKUP_BUCKET}/world-backups/" --config /etc/luanti/rclone.conf
  mapfile -t remote < <(rclone lsf "linode:${BACKUP_BUCKET}/world-backups/" --config /etc/luanti/rclone.conf | grep -E '^world-.*\.tar\.gz$' | sort -r || true)
  if ((${#remote[@]} > BACKUP_RETENTION)); then
    for old in "${remote[@]:BACKUP_RETENTION}"; do
      rclone deletefile "linode:${BACKUP_BUCKET}/world-backups/${old}" --config /etc/luanti/rclone.conf
    done
  fi
fi

systemctl start luanti.service
trap - EXIT
