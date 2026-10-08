#!/bin/bash
# Restore a world tarball over the current world.
# Usage: luanti-restore /var/lib/luanti/backups/world-STAMP.tar.gz
#        luanti-restore s3:world-STAMP.tar.gz
#
# The archive must contain a top-level directory named WORLD_NAME.
# If extraction fails, the previous world directory is moved back.
set -euo pipefail

WORLD_NAME="${WORLD_NAME:-}"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"

# shellcheck disable=SC1091
source /etc/luanti/server.env

: "${WORLD_NAME:?WORLD_NAME missing}"

src="${1:-}"
if [[ -z "$src" ]]; then
  echo "usage: luanti-restore <local-tar-or-s3:key>" >&2
  exit 1
fi

exec 9>/var/lock/luanti-admin.lock
flock 9

workdir="$(mktemp -d)"
start_again=0
cleanup() {
  rm -rf "$workdir"
  if [[ "$start_again" == 1 ]]; then
    systemctl start luanti.service || true
  fi
}
trap cleanup EXIT

archive="$src"
if [[ "$src" == s3:* ]]; then
  : "${BACKUP_BUCKET:?BACKUP_BUCKET missing}"
  key="${src#s3:}"
  archive="${workdir}/$(basename "$key")"
  rclone copyto "linode:${BACKUP_BUCKET}/world-backups/${key}" "$archive" --config /etc/luanti/rclone.conf
fi

if [[ ! -f "$archive" ]]; then
  echo "archive not found: $archive" >&2
  exit 1
fi

listing="$(tar -tzf "$archive")"
found=0
while IFS= read -r entry; do
  if [[ "$entry" == "${WORLD_NAME}/"* ]]; then
    found=1
    break
  fi
done <<<"$listing"
if [[ "$found" != 1 ]]; then
  echo "archive does not contain a ${WORLD_NAME}/ directory" >&2
  exit 1
fi

worlds="/var/lib/luanti/data/.minetest/worlds"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
current="${worlds}/${WORLD_NAME}"
aside="${current}.pre-restore-${stamp}"

systemctl stop luanti.service
start_again=1

moved=0
if [[ -d "$current" ]]; then
  mv "$current" "$aside"
  moved=1
  echo "moved current world to ${aside}"
fi

restore_previous() {
  rm -rf "$current"
  if [[ "$moved" == 1 ]]; then
    mv "$aside" "$current"
    echo "put the previous world back"
  fi
}

if ! tar -C "$worlds" -xzf "$archive"; then
  echo "extract failed" >&2
  restore_previous
  exit 1
fi

if [[ ! -d "$current" ]]; then
  echo "archive did not recreate ${current}" >&2
  restore_previous
  exit 1
fi

chown -R 30000:30000 "$current"
echo "restored ${WORLD_NAME} from ${src}"
systemctl start luanti.service
start_again=0
