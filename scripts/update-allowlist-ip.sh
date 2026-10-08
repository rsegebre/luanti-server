#!/usr/bin/env bash
# Detect this machine's public IP and rewrite the allowlists in terraform.tfvars.
#
# The first IPv4 entry and the first IPv6 entry in each selected list are the
# "this house" prefixes. Extra friends stay later in the list. IPv4 is stored
# as a /32. IPv6 is stored as the /64, because residential providers rotate the
# interface ID inside a stable household prefix.
#
# Updates both admin_cidrs and player_cidrs unless --only is set. SSH uses
# admin_cidrs, so a home-IP change has to update that list or the next apply
# cannot reconnect.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tfvars="${root}/main/terraform.tfvars"
only="both"
dry_run=0
skip_ipv6=0
ipv4=""
ipv6=""

usage() {
  cat <<'EOF'
usage: scripts/update-allowlist-ip.sh [options]

  --tfvars PATH     File to edit (default: main/terraform.tfvars)
  --only player|admin|both
                    Which list to update (default: both)
  --ipv4 ADDR       Use this IPv4 instead of detecting it
  --ipv6 ADDR       Use this IPv6 instead of detecting it
  --skip-ipv6       Leave IPv6 prefixes unchanged
  --dry-run         Print the new lists and do not write the file
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars)
      tfvars="${2:?--tfvars needs a path}"
      shift 2
      ;;
    --only)
      only="${2:?--only needs player, admin, or both}"
      shift 2
      ;;
    --ipv4)
      ipv4="${2:?--ipv4 needs an address}"
      shift 2
      ;;
    --ipv6)
      ipv6="${2:?--ipv6 needs an address}"
      shift 2
      ;;
    --skip-ipv6)
      skip_ipv6=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$only" in
  player | admin | both) ;;
  *)
    echo "--only must be player, admin, or both" >&2
    exit 1
    ;;
esac

if [[ ! -f "$tfvars" ]]; then
  example="${root}/main/terraform.tfvars.example"
  if [[ ! -f "$example" ]]; then
    echo "tfvars file not found: $tfvars" >&2
    exit 1
  fi
  cp "$example" "$tfvars"
  echo "created ${tfvars} from the example"
fi

if [[ -z "$ipv4" ]]; then
  ipv4="$(curl -4 -fsS --max-time 15 https://api.ipify.org)"
fi

if [[ "$skip_ipv6" -eq 0 && -z "$ipv6" ]]; then
  if ! ipv6="$(curl -6 -fsS --max-time 15 https://api6.ipify.org)"; then
    echo "no public IPv6 detected; leaving existing IPv6 prefixes" >&2
    skip_ipv6=1
    ipv6=""
  fi
fi

export ALLOWLIST_TFVARS="$tfvars"
export ALLOWLIST_ONLY="$only"
export ALLOWLIST_IPV4="$ipv4"
export ALLOWLIST_IPV6="$ipv6"
export ALLOWLIST_SKIP_IPV6="$skip_ipv6"
export ALLOWLIST_DRY_RUN="$dry_run"

python3 - <<'PY'
import ipaddress
import os
import re
import sys

path = os.environ["ALLOWLIST_TFVARS"]
only = os.environ["ALLOWLIST_ONLY"]
dry = os.environ["ALLOWLIST_DRY_RUN"] == "1"
skip_v6 = os.environ["ALLOWLIST_SKIP_IPV6"] == "1"

def v4_cidr(text):
    text = text.strip()
    if "/" not in text:
        text = text + "/32"
    net = ipaddress.ip_network(text, strict=False)
    if net.version != 4:
        raise ValueError("not IPv4: " + text)
    if net.prefixlen != 32:
        raise ValueError("IPv4 allowlist entries from this script are a single /32, got " + text)
    return str(net)

def v6_prefix(text):
    text = text.strip()
    if "/" not in text:
        addr = ipaddress.ip_address(text)
        if addr.version != 6:
            raise ValueError("not IPv6: " + text)
        net = ipaddress.ip_network(f"{addr}/64", strict=False)
    else:
        net = ipaddress.ip_network(text, strict=False)
        if net.version != 6:
            raise ValueError("not IPv6: " + text)
        net = ipaddress.ip_network(f"{net.network_address}/64", strict=False)
    return f"{net.network_address}/{net.prefixlen}"

new_v4 = v4_cidr(os.environ["ALLOWLIST_IPV4"])
new_v6 = None if skip_v6 else v6_prefix(os.environ["ALLOWLIST_IPV6"])

text = open(path, encoding="utf-8").read()
targets = ["player_cidrs", "admin_cidrs"] if only == "both" else {
    "player": ["player_cidrs"],
    "admin": ["admin_cidrs"],
}[only]

assignment = re.compile(
    r"(?P<indent>[ \t]*)(?P<name>player_cidrs|admin_cidrs)[ \t]*=[ \t]*\[(?P<body>.*?)\]",
    re.S,
)

def split_entries(body):
    return re.findall(r'"([^"]*)"', body)

def render(name, entries, indent):
    inner = ",\n".join(f'{indent}  "{item}"' for item in entries)
    return f"{indent}{name} = [\n{inner},\n{indent}]"

found = {name: False for name in targets}

def replace(match):
    name = match.group("name")
    if name not in targets:
        return match.group(0)
    found[name] = True
    entries = split_entries(match.group("body"))
    if not entries:
        sys.exit(f"{name} has no quoted entries to update")
    updated = list(entries)
    replaced_v4 = False
    replaced_v6 = False
    for i, entry in enumerate(updated):
        if not replaced_v4 and ":" not in entry:
            print(f"{name}: {entry} -> {new_v4}")
            updated[i] = new_v4
            replaced_v4 = True
        elif new_v6 and not replaced_v6 and ":" in entry:
            print(f"{name}: {entry} -> {new_v6}")
            updated[i] = new_v6
            replaced_v6 = True
    if not replaced_v4:
        print(f"{name}: append {new_v4}")
        updated.append(new_v4)
    if new_v6 and not replaced_v6:
        print(f"{name}: append {new_v6}")
        updated.append(new_v6)
    return render(name, updated, match.group("indent"))

new_text, count = assignment.subn(replace, text)
missing = [name for name, ok in found.items() if not ok]
if missing:
    sys.exit("did not find assignment for: " + ", ".join(missing))
if count == 0:
    sys.exit("no allowlist assignments were rewritten")

if dry:
    sys.stdout.write(new_text)
else:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(new_text)
    print(f"wrote {path}")
    print("Next: terraform plan. A CIDR-only change updates the firewall and does not rebuild the VM.")
PY
