#!/bin/bash
# Foreground Luanti container. systemd tracks this process.
set -euo pipefail

LUANTI_IMAGE="${LUANTI_IMAGE:-}"
LUANTI_PORT="${LUANTI_PORT:-30000}"
GAME_ID="${GAME_ID:-}"
WORLD_NAME="${WORLD_NAME:-}"
PUBLISH_IPV6="${PUBLISH_IPV6:-true}"

# shellcheck disable=SC1091
source /etc/luanti/server.env

: "${LUANTI_IMAGE:?LUANTI_IMAGE missing}"
: "${LUANTI_PORT:?LUANTI_PORT missing}"
: "${GAME_ID:?GAME_ID missing}"
: "${WORLD_NAME:?WORLD_NAME missing}"

publish=(-p "0.0.0.0:${LUANTI_PORT}:${LUANTI_PORT}/udp")
if [[ "$PUBLISH_IPV6" == "true" ]]; then
  publish+=(-p "[::]:${LUANTI_PORT}:${LUANTI_PORT}/udp")
fi

exec /usr/bin/docker run \
  --name luanti \
  --rm \
  --pull never \
  "${publish[@]}" \
  -v /var/lib/luanti/data:/var/lib/minetest \
  -v /etc/luanti/minetest.conf:/etc/minetest/minetest.conf:ro \
  -v /var/lib/luanti/password-drop:/var/lib/minetest/password-drop \
  "$LUANTI_IMAGE" \
  --config /etc/minetest/minetest.conf \
  --gameid "$GAME_ID" \
  --worldname "$WORLD_NAME"
