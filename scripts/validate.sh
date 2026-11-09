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
if ! grep -q 'name: luantistats' "$rendered/cloud-init.yaml"; then
  echo "rendered cloud-init is missing the stats user" >&2
  exit 1
fi
# The shell script is embedded literally, so these are not expanded here.
# shellcheck disable=SC2016
if ! grep -F -q 'AllowUsers root ${admin_user} ${stats_user}' "$rendered/cloud-init.yaml"; then
  echo "rendered cloud-init is missing the stats AllowUsers entry" >&2
  exit 1
fi
if ! grep -F -q 'luanti-host-bootstrap, "luanti-world", "luantiadmin", "luantistats"' "$rendered/cloud-init.yaml"; then
  echo "rendered cloud-init does not pass the stats user to host bootstrap" >&2
  exit 1
fi
python3 "$root/scripts/luanti-weekly-stats.py" --self-test
python3 "$root/scripts/ci-firewall-ssh-only.py" --self-test
if STATS_SSH_PRIVATE_KEY='' "$root/scripts/ci-require-stats-key.sh" >/dev/null 2>&1; then
  echo "stats key check accepted an empty private key" >&2
  exit 1
fi
echo "validate: terraform, shellcheck, cloud-init schema, and stats checks passed"
