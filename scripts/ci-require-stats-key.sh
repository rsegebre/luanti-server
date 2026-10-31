#!/usr/bin/env bash
# Fail closed before the weekly stats job opens SSH.
# Prints the stats username on stdout. Does not print either half of the key.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [[ -z "${STATS_SSH_PRIVATE_KEY:-}" ]]; then
  echo "luanti-stats environment secret STATS_SSH_PRIVATE_KEY is empty" >&2
  exit 1
fi
if [[ "$STATS_SSH_PRIVATE_KEY" != *"PRIVATE KEY"* ]]; then
  echo "STATS_SSH_PRIVATE_KEY is not an OpenSSH or PEM private key" >&2
  exit 1
fi

python3 - <<'PY'
import re
import sys
from pathlib import Path

text = Path("main/terraform.tfvars").read_text(encoding="utf-8")
user = re.search(r'(?m)^stats_user\s*=\s*"([a-z][a-z0-9-]{0,30})"\s*$', text)
key = re.search(
    r'(?m)^stats_ssh_public_key\s*=\s*"((?:ssh-|ecdsa-|sk-ssh-)[^"]*)"\s*$',
    text,
)
if not user:
    sys.exit("stats_user is missing from main/terraform.tfvars")
if user.group(1) in {"root", "luantiadmin"}:
    sys.exit("stats_user must not be root or the sudo user")
if not key or not key.group(1).strip():
    sys.exit(
        "stats_ssh_public_key in main/terraform.tfvars is empty. "
        "Generate a key, commit the public half, and apply before this job can SSH."
    )
if "command=" in key.group(1) or "no-port-forwarding" in key.group(1):
    sys.exit("stats_ssh_public_key must be the raw public key, without authorized_keys options")
print(user.group(1))
PY
