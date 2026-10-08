#!/bin/bash
# Ask for a password and hand it to the allowlist mod, which writes the auth database.
# The password is not stored in Terraform, shell history, or the world tarball.
set -euo pipefail

name="${1:-}"
if [[ -z "$name" ]]; then
  echo "usage: luanti-setpassword <playername>" >&2
  exit 1
fi
if [[ ! "$name" =~ ^[A-Za-z0-9_-]{1,20}$ ]]; then
  echo "player name must be 1-20 characters: letters, digits, underscore, hyphen" >&2
  exit 1
fi

read -r -s -p "Password for ${name}: " password
printf '\n'
read -r -s -p "Repeat password: " password2
printf '\n'

if [[ "$password" != "$password2" ]]; then
  echo "passwords do not match" >&2
  exit 1
fi
if [[ -z "$password" ]]; then
  echo "empty passwords are not allowed" >&2
  exit 1
fi
if [[ "$password" == *$'\n'* || "$password" == *$'\t'* ]]; then
  echo "password must not contain tabs or newlines" >&2
  exit 1
fi

drop="/var/lib/luanti/password-drop"
install -d -m 0700 -o 30000 -g 30000 "$drop"
if [[ -e "${drop}/lock" ]]; then
  echo "a password update is already in progress" >&2
  exit 1
fi
mkdir "${drop}/lock"
trap 'rmdir /var/lib/luanti/password-drop/lock 2>/dev/null || true' EXIT

rm -f "${drop}/pending.result"
tmp="$(mktemp)"
chmod 0600 "$tmp"
printf '%s\t%s\n' "$name" "$password" >"$tmp"
unset password password2
install -m 0600 -o 30000 -g 30000 "$tmp" "${drop}/pending"
rm -f "$tmp"

echo "waiting for the server to apply the password"
result=""
for _ in $(seq 1 30); do
  if [[ -f "${drop}/pending.result" ]]; then
    result="$(cat "${drop}/pending.result")"
    rm -f "${drop}/pending.result"
    break
  fi
  sleep 1
done

if [[ -z "$result" ]]; then
  echo "timed out. Is luanti.service active and is player_allowlist trusted?" >&2
  exit 1
fi

printf '%s\n' "$result"
if [[ "$result" != "ok ${name}" ]]; then
  exit 1
fi
