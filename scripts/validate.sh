#!/usr/bin/env bash
# Local checks that do not call Linode or Cloudflare.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

terraform fmt -check -recursive "$root"

terraform -chdir="$root/bootstrap" init -backend=false -input=false
terraform -chdir="$root/bootstrap" validate

terraform -chdir="$root/main" init -backend=false -input=false
terraform -chdir="$root/main" validate

shellcheck \
  "$root/scripts/"*.sh \
  "$root/main/files/"*.sh

rendered="$(mktemp -d)"
trap 'rm -rf "$rendered"' EXIT
"$root/scripts/render-configs.sh" "$rendered"
cloud-init schema --config-file "$rendered/cloud-init.yaml"
echo "validate: terraform, shellcheck, and cloud-init schema passed"
