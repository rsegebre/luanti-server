#!/usr/bin/env bash
# Fail closed before apply if the CI deploy keypair is not configured.
# Prints counts only, never the private key.
set -euo pipefail

if [[ -z "${DEPLOY_SSH_PRIVATE_KEY:-}" ]]; then
  echo "production environment secret DEPLOY_SSH_PRIVATE_KEY is empty" >&2
  exit 1
fi

python3 - <<'PY'
import re
import sys
from pathlib import Path

text = Path("main/terraform.tfvars").read_text(encoding="utf-8")
match = re.search(r"(?m)^deploy_ssh_public_keys\s*=\s*\[(.*?)\]", text, re.S)
body = match.group(1) if match else ""
keys = re.findall(r'"(?:ssh-|ecdsa-|sk-ssh-)[^"]+"', body)
if not keys:
    sys.exit(
        "commit at least one entry in deploy_ssh_public_keys in "
        "main/terraform.tfvars before the first apply"
    )
print(f"deploy public keys configured: {len(keys)}")
PY
