#!/usr/bin/env bash
# Run the pinned Luanti image with the Terraform-rendered config and allowlist.
# Does not call Linode or Cloudflare. Requires Docker and a clone of Minetest Game.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="${root}/.rendered/smoke"
image="ghcr.io/luanti-org/luanti:5.17.0"
game_url="https://github.com/luanti-org/minetest_game.git"
game_ref="c42e4d0c0ff9d27ff7b9b308c3cfc14098dd3a0f"
anvil_url="https://github.com/minetest-mods/anvil.git"
anvil_ref="9bc6f63af822269c16db69cc0f8e4710207aa1a7"
creatura_url="https://github.com/ElCeejo/creatura.git"
creatura_ref="4eb507cf2433f0787691f560842deea79a1666f4"
animalia_url="https://github.com/ElCeejo/animalia.git"
animalia_ref="5895f403fd43a9464e06b3675af3495f50565a3f"
i3_url="https://github.com/mt-historical/i3.git"
i3_ref="6f60b2446f32e2a4d73d80b1f71f58e9b1e4870c"
farming_url="https://codeberg.org/tenplus1/farming.git"
farming_ref="fbe17a9fbe2a95003b8b71b98d6bb49d5079dd37"
nether_url="https://github.com/minetest-mods/nether.git"
nether_ref="c34722d42678a034e3546cbd6ff9774697f5351b"
container="luanti-smoke"
worldmods="${render}/data/.minetest/worlds/world/worldmods"

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

# anvil is a small Minetest Game mod (depends on default, which this game ships).
# The installer is the same script the config push runs.
cat >"$render/server.env" <<'EOF'
WORLD_NAME=world
EOF

run_mods() {
  LUANTI_SERVER_ENV="$render/server.env" \
    LUANTI_ROOT="$render" \
    LUANTI_MODS_MANIFEST="$render/mods.manifest" \
    LUANTI_LOCK_FILE="$render/luanti-admin.lock" \
    "$root/main/files/luanti-mods.sh"
}

printf '%s\n' "# name git_url git_ref subdir" >"$render/mods.manifest"
mkdir -p "$worldmods/left_behind"
run_mods
if [[ -d "$worldmods/left_behind" ]]; then
  echo "smoke: installer left an unlisted worldmods directory in place" >&2
  exit 1
fi
if [[ ! -d "$worldmods/player_allowlist" ]]; then
  echo "smoke: installer removed player_allowlist" >&2
  exit 1
fi

cat >"$render/mods.manifest" <<EOF
# name git_url git_ref subdir
player_allowlist ${anvil_url} ${anvil_ref} .
EOF
if run_mods; then
  echo "smoke: installer accepted player_allowlist" >&2
  exit 1
fi

cat >"$render/mods.manifest" <<EOF
# name git_url git_ref subdir
anvil ${anvil_url} ${anvil_ref} .
EOF
run_mods
if [[ ! -f "$worldmods/anvil/init.lua" ]]; then
  echo "smoke: anvil was not installed" >&2
  exit 1
fi
if [[ -d "$worldmods/anvil/.git" ]]; then
  echo "smoke: anvil copy contains .git" >&2
  exit 1
fi
run_mods
printf '%s\n' "# name git_url git_ref subdir" >"$render/mods.manifest"
run_mods
if [[ -d "$worldmods/anvil" || -d "$render/mod-src/anvil" ]]; then
  echo "smoke: removing anvil from the manifest left it installed" >&2
  exit 1
fi
if [[ ! -d "$worldmods/player_allowlist" ]]; then
  echo "smoke: removing mods also removed player_allowlist" >&2
  exit 1
fi
# The server boots the same list as main/terraform.tfvars. Installing it also
# prunes the anvil copy the installer tests left behind.
cat >"$render/mods.manifest" <<EOF
# name git_url git_ref subdir
creatura ${creatura_url} ${creatura_ref} .
animalia ${animalia_url} ${animalia_ref} .
i3 ${i3_url} ${i3_ref} .
farming ${farming_url} ${farming_ref} .
nether ${nether_url} ${nether_ref} .
EOF
run_mods
for mod_name in creatura animalia i3 farming nether; do
  if [[ ! -f "$worldmods/${mod_name}/init.lua" ]]; then
    echo "smoke: ${mod_name} was not installed" >&2
    exit 1
  fi
  if [[ -d "$worldmods/${mod_name}/.git" ]]; then
    echo "smoke: ${mod_name} copy contains .git" >&2
    exit 1
  fi
done
if [[ -d "$worldmods/anvil" ]]; then
  echo "smoke: production mod list left anvil installed" >&2
  exit 1
fi
if [[ ! -d "$worldmods/player_allowlist" ]]; then
  echo "smoke: production mod list removed player_allowlist" >&2
  exit 1
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
  --worldname world \
  --info

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

logs=""
ready=0
for _ in $(seq 1 60); do
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
# Luanti flushes infostream every 256 bytes (src/log.h BUFFER_LENGTH), so
# "Server: Loading mods:" is split across consecutive INFO lines. Join them
# before checking names.
printf '%s\n' "$logs" >"$render/server.log"
load_line="$(python3 - "$render/server.log" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
marker = "INFO[Main]: "
buf = None
for line in lines:
    idx = line.find(marker)
    payload = line[idx + len(marker):] if idx >= 0 else None
    if buf is None:
        prefix = "Server: Loading mods:"
        if payload is not None and payload.startswith(prefix):
            buf = payload[len(prefix):]
        continue
    if payload is None or payload.startswith(("Mod ", "Server:", "All mods")):
        break
    buf += payload
print(buf or "")
PY
)"
for mod_name in creatura animalia i3 farming nether; do
  if ! printf '%s\n' "$load_line" | tr ' ' '\n' | grep -qx "$mod_name"; then
    echo "smoke: ${mod_name} was not in the Server: Loading mods list (--info)" >&2
    printf '%s\n' "$logs" | tail -n 80 >&2
    exit 1
  fi
done
farming_count="$(printf '%s\n' "$load_line" | tr ' ' '\n' | grep -cx farming || true)"
if [[ "$farming_count" != 1 ]]; then
  echo "smoke: expected one farming mod in the load list, found ${farming_count}" >&2
  printf '%s\n' "$load_line" >&2
  exit 1
fi
if ! grep -F 'Mod name conflict detected: "farming"' <<<"$logs" >/dev/null; then
  echo "smoke: Farming Redo did not override Minetest Game farming" >&2
  printf '%s\n' "$logs" | tail -n 80 >&2
  exit 1
fi
if ! grep -F 'Overridden by' <<<"$logs" | grep -F 'worldmods/farming' >/dev/null; then
  echo "smoke: farming override did not come from worldmods/farming" >&2
  printf '%s\n' "$logs" | tail -n 40 >&2
  exit 1
fi
if grep -E -e 'ModError' -e 'unsatisfied dependenc' -e 'Failed to load and run script' <<<"$logs" >/dev/null; then
  echo "smoke: mod loading reported an error" >&2
  printf '%s\n' "$logs" | tail -n 80 >&2
  exit 1
fi
if grep -F -e 'Announcing start to' -e 'Announcing update to' <<<"$logs" >/dev/null; then
  echo "smoke: server is announcing" >&2
  exit 1
fi

printf 'rss1989\tsmoke-test-secret\n' >"$render/password-drop/pending"
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
if [[ "$result" != "ok rss1989" ]]; then
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
        sys.exit(f"rss1989 is missing privilege {required}")
PY

python3 "$root/scripts/luanti_probe.py" 127.0.0.1 30000 NotAFriend
sleep 2
logs="$(docker logs "$container" 2>&1 || true)"
if ! grep -F -q "[player_allowlist] rejected name 'NotAFriend'" <<<"$logs"; then
  echo "smoke: stranger name was not rejected in the server log" >&2
  printf '%s\n' "$logs" | tail -n 60 >&2
  exit 1
fi

echo "smoke: server started, did not announce, loaded creatura animalia i3 farming nether and the allowlist, overrode Minetest Game farming, set a password, and rejected NotAFriend"
