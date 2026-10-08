#!/usr/bin/env bash
# Run the pinned Luanti image with the Terraform-rendered config and allowlist.
# Does not call Linode or Cloudflare. Requires Docker and a clone of Minetest Game.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="${root}/.rendered/smoke"
image="ghcr.io/luanti-org/luanti:5.17.0"
game_url="https://github.com/luanti-org/minetest_game.git"
game_ref="c42e4d0c0ff9d27ff7b9b308c3cfc14098dd3a0f"
container="luanti-smoke"

if ! docker info >/dev/null 2>&1; then
  echo "docker is not reachable" >&2
  exit 1
fi

rm -rf "$render"
mkdir -p \
  "$render/data/.minetest/games" \
  "$render/data/.minetest/worlds/world/worldmods/player_allowlist" \
  "$render/password-drop" \
  "$render/etc"

"$root/scripts/render-configs.sh" "$render/generated"
cp "$render/generated/minetest.conf" "$render/etc/minetest.conf"
cp "$render/generated/world.mt" "$render/data/.minetest/worlds/world/world.mt"
cp "$render/generated/init.lua" "$render/data/.minetest/worlds/world/worldmods/player_allowlist/init.lua"
cp "$render/generated/mod.conf" "$render/data/.minetest/worlds/world/worldmods/player_allowlist/mod.conf"

if ! grep -q 'server_announce = false' "$render/etc/minetest.conf"; then
  echo "rendered config does not set server_announce = false" >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*server_address|^[[:space:]]*server_url' "$render/etc/minetest.conf"; then
  echo "rendered config sets server_address or server_url" >&2
  exit 1
fi

game="${render}/data/.minetest/games/minetest_game"
if [[ ! -f "${game}/game.conf" ]]; then
  rm -rf "$game"
  mkdir -p "$game"
  git -C "$game" init
  git -C "$game" remote add origin "$game_url"
  git -C "$game" fetch --depth 1 origin "$game_ref"
  git -C "$game" checkout --detach FETCH_HEAD
  if [[ -f "${game}/.gitmodules" ]]; then
    git -C "$game" submodule update --init --recursive --depth 1
  fi
fi

docker pull "$image"
docker rm -f "$container" >/dev/null 2>&1 || true

# The image runs as uid 30000. The password drop is mode 0700 for that uid.
chown -R 30000:30000 "$render/data" "$render/password-drop"
chmod 0700 "$render/password-drop"

docker run \
  --name "$container" \
  --rm \
  --detach \
  --publish 127.0.0.1:30000:30000/udp \
  --volume "${render}/data:/var/lib/minetest" \
  --volume "${render}/etc/minetest.conf:/etc/minetest/minetest.conf:ro" \
  --volume "${render}/password-drop:/var/lib/minetest/password-drop" \
  "$image" \
  --config /etc/minetest/minetest.conf \
  --gameid minetest_game \
  --worldname world

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

logs=""
ready=0
for _ in $(seq 1 45); do
  logs="$(docker logs "$container" 2>&1 || true)"
  if grep -F -q '[player_allowlist] loaded' <<<"$logs"; then
    ready=1
    break
  fi
  if grep -F -q 'ERROR' <<<"$logs" && grep -F -q 'Server:' <<<"$logs"; then
    break
  fi
  sleep 2
done

printf '%s\n' "$logs" | tail -n 40
if [[ "$ready" != 1 ]]; then
  echo "smoke: allowlist mod did not load" >&2
  exit 1
fi
if grep -F -e 'Announcing start to' -e 'Announcing update to' <<<"$logs" >/dev/null; then
  echo "smoke: server is announcing" >&2
  exit 1
fi

printf 'admin\tsmoke-test-secret\n' >"$render/password-drop/pending"
chown 30000:30000 "$render/password-drop/pending"
chmod 0600 "$render/password-drop/pending"
password_ok=0
for _ in $(seq 1 20); do
  if [[ -f "$render/password-drop/pending.result" ]]; then
    password_ok=1
    break
  fi
  sleep 1
done
if [[ "$password_ok" != 1 ]]; then
  echo "smoke: password drop produced no result" >&2
  docker logs "$container" 2>&1 | tail -n 40 >&2 || true
  exit 1
fi
result="$(cat "$render/password-drop/pending.result")"
printf 'password result: %s\n' "$result"
if [[ "$result" != "ok admin" ]]; then
  echo "smoke: unexpected password result" >&2
  exit 1
fi

python3 - "$render/data/.minetest/worlds/world/auth.sqlite" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
privs = [row[0] for row in con.execute("SELECT privilege FROM user_privileges")]
print("privileges:", " ".join(sorted(privs)))
if any('"' in priv or priv.startswith(" ") for priv in privs):
    sys.exit("privilege names include quotes or spaces; minetest.conf values were parsed wrong")
for required in ("interact", "shout", "privs", "server", "ban"):
    if required not in privs:
        sys.exit(f"admin is missing privilege {required}")
PY

python3 "$root/scripts/luanti_probe.py" 127.0.0.1 30000 NotAFriend
sleep 2
logs="$(docker logs "$container" 2>&1 || true)"
if ! grep -F -q "[player_allowlist] rejected name 'NotAFriend'" <<<"$logs"; then
  echo "smoke: stranger name was not rejected in the server log" >&2
  printf '%s\n' "$logs" | tail -n 60 >&2
  exit 1
fi

echo "smoke: server started, did not announce, loaded the allowlist, set a password, and rejected NotAFriend"
