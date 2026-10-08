#!/bin/bash
# Install pinned mods into the world's worldmods directory.
# Safe to re-run. Removes worldmods entries that are no longer listed.
# Does not delete player_allowlist or any world database files.
set -euo pipefail

WORLD_NAME="${WORLD_NAME:-}"
LUANTI_SERVER_ENV="${LUANTI_SERVER_ENV:-/etc/luanti/server.env}"
LUANTI_ROOT="${LUANTI_ROOT:-/var/lib/luanti}"

# shellcheck disable=SC1090
source "$LUANTI_SERVER_ENV"

: "${WORLD_NAME:?WORLD_NAME missing}"

manifest="${LUANTI_MODS_MANIFEST:-${LUANTI_ROOT}/mods.manifest}"
worldmods="${LUANTI_ROOT}/data/.minetest/worlds/${WORLD_NAME}/worldmods"
src_root="${LUANTI_ROOT}/mod-src"

export GIT_TERMINAL_PROMPT=0

if [[ ! -f "$manifest" ]]; then
  echo "mods manifest not found: ${manifest}" >&2
  exit 1
fi

# Same lock file as luanti-install and luanti-backup so a mod copy does not
# overlap a backup or a restart. Smoke tests set LUANTI_LOCK_FILE.
lock_file="${LUANTI_LOCK_FILE:-/var/lock/luanti-admin.lock}"
mkdir -p -- "$(dirname -- "$lock_file")"
exec 9>"$lock_file"
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

install -d -m 0755 "$worldmods" "$src_root"

stage=""
cleanup_stage() {
  if [[ -n "$stage" && -d "$stage" ]]; then
    rm -rf -- "$stage"
  fi
}
trap cleanup_stage EXIT

declared_name() {
  local dir="$1"
  local file="" raw
  if [[ -f "${dir}/mod.conf" ]]; then
    file="${dir}/mod.conf"
  elif [[ -f "${dir}/modpack.conf" ]]; then
    file="${dir}/modpack.conf"
  else
    printf ''
    return 0
  fi
  raw="$(sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*//p' "$file" | head -n 1 || true)"
  raw="${raw%%#*}"
  printf '%s' "$raw" | tr -d "[:space:]\"'"
}

is_mod_tree() {
  local dir="$1"
  [[ -f "${dir}/init.lua" || -f "${dir}/modpack.conf" || -f "${dir}/modpack.txt" ]]
}

names=()
urls=()
refs=()
subdirs=()
declare -A want=()

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  [[ "$line" =~ ^# ]] && continue
  if [[ ! "$line" =~ ^([a-z0-9_]+)[[:space:]]+(https://[^[:space:]]+)[[:space:]]+([0-9a-f]{40})[[:space:]]+([^[:space:]]+)$ ]]; then
    echo "invalid mods manifest line: ${line}" >&2
    exit 1
  fi
  name="${BASH_REMATCH[1]}"
  url="${BASH_REMATCH[2]}"
  ref="${BASH_REMATCH[3]}"
  subdir="${BASH_REMATCH[4]}"
  if [[ "$name" == "player_allowlist" ]]; then
    echo "refusing to manage player_allowlist" >&2
    exit 1
  fi
  if [[ -n "${want[$name]:-}" ]]; then
    echo "duplicate mod name: ${name}" >&2
    exit 1
  fi
  if [[ "$subdir" != "." && "$subdir" == *".."* ]]; then
    echo "invalid subdir: ${subdir}" >&2
    exit 1
  fi
  want["$name"]=1
  names+=("$name")
  urls+=("$url")
  refs+=("$ref")
  subdirs+=("$subdir")
done <"$manifest"

install_one() {
  local name="$1" url="$2" ref="$3" subdir="$4"
  local src="${src_root}/${name}"
  local dest="${worldmods}/${name}"
  local pin="${ref} ${subdir} ${url}"
  local src_real sub_real got

  if [[ ! -f "${src}/.pinned-ref" ]] || [[ "$(cat "${src}/.pinned-ref")" != "$pin" ]] || [[ ! -d "${src}/.git" ]]; then
    rm -rf -- "$src"
    mkdir -p -- "$src"
    git -C "$src" init
    git -C "$src" remote add origin "$url"
    retry git -C "$src" fetch --depth 1 origin "$ref"
    git -C "$src" checkout --detach FETCH_HEAD
    if [[ -f "${src}/.gitmodules" ]]; then
      git -C "$src" submodule update --init --recursive --depth 1
    fi
    got="$(git -C "$src" rev-parse HEAD)"
    if [[ "$got" != "$ref" ]]; then
      echo "checkout of ${name} is ${got}, expected ${ref}" >&2
      exit 1
    fi
    printf '%s\n' "$pin" >"${src}/.pinned-ref"
    echo "luanti-mods: fetched ${name} ${ref}"
  else
    echo "luanti-mods: checkout ${name} unchanged"
  fi

  src_real="$(realpath "$src")"
  sub_real="$(realpath -m "${src}/${subdir}")"
  case "$sub_real" in
    "$src_real" | "$src_real"/*) ;;
    *)
      echo "subdir escapes the checkout for ${name}: ${subdir}" >&2
      exit 1
      ;;
  esac
  if [[ ! -d "$sub_real" ]]; then
    echo "subdir not found for ${name}: ${subdir}" >&2
    exit 1
  fi
  if ! is_mod_tree "$sub_real"; then
    echo "${name}: ${subdir} has no init.lua, modpack.conf, or modpack.txt" >&2
    exit 1
  fi

  if [[ -f "${dest}/.pinned-ref" ]] && [[ "$(cat "${dest}/.pinned-ref")" == "$pin" ]] && is_mod_tree "$dest"; then
    echo "luanti-mods: ${name} unchanged"
    return 0
  fi

  stage="$(mktemp -d "${worldmods}/.stage-${name}.XXXXXX")"
  cp -a "${sub_real}/." "${stage}/"
  rm -rf -- "${stage}/.git"
  got="$(declared_name "$stage")"
  if [[ -n "$got" && "$got" != "$name" ]]; then
    echo "mod name mismatch: ${name} but mod.conf says ${got}" >&2
    exit 1
  fi
  printf '%s\n' "$pin" >"${stage}/.pinned-ref"
  rm -rf -- "$dest"
  mv -- "$stage" "$dest"
  stage=""
  echo "luanti-mods: installed ${name}"
}

for i in "${!names[@]}"; do
  install_one "${names[$i]}" "${urls[$i]}" "${refs[$i]}" "${subdirs[$i]}"
done

prune_children() {
  local parent="$1" keep_allowlist="$2"
  local path base
  shopt -s nullglob
  for path in "${parent}"/*; do
    base="$(basename -- "$path")"
    if [[ "$keep_allowlist" == "yes" && "$base" == "player_allowlist" ]]; then
      continue
    fi
    if [[ -n "${want[$base]:-}" ]]; then
      continue
    fi
    if [[ -d "$path" || -L "$path" ]]; then
      echo "luanti-mods: removing ${path}"
      # No trailing slash: a symlink is removed, not its target.
      rm -rf -- "$path"
    fi
  done
  shopt -u nullglob
}

prune_children "$worldmods" yes
prune_children "$src_root" no

echo "luanti-mods: ${#names[@]} mod(s) installed"
