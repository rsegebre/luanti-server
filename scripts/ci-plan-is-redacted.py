#!/usr/bin/env python3
"""Refuse to publish a plan that still contains a configured secret."""

import os
import sys
from pathlib import Path

def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: ci-plan-is-redacted.py PLAN.txt")
    text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    names = [
        "TF_VAR_backups_access_key",
        "TF_VAR_backups_secret_key",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "LINODE_TOKEN",
        "CLOUDFLARE_API_TOKEN",
        "DEPLOY_SSH_PRIVATE_KEY",
    ]
    for name in names:
        value = os.environ.get(name, "")
        if len(value) >= 8 and value in text:
            sys.exit(f"refusing to publish the plan: it contains {name}")
    if "BEGIN OPENSSH PRIVATE KEY" in text or "BEGIN RSA PRIVATE KEY" in text:
        sys.exit("refusing to publish the plan: it contains a private key")


if __name__ == "__main__":
    main()
