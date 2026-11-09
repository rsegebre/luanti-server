#!/usr/bin/env bash
# Plan linode_firewall.luanti and apply the saved plan only when the only
# change is the runner's SSH /32.
#
#   ci-firewall-ssh-apply.sh open  203.0.113.10
#   ci-firewall-ssh-apply.sh close 203.0.113.10
#
# open sets ci_ssh_cidrs to that host. close sets it back to empty.
# The private deploy key is never set. This does not SSH.
set -euo pipefail

mode="${1:?mode open or close required}"
ipv4="${2:?runner IPv4 required}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$ipv4"

case "$mode" in
  open)
    export TF_VAR_ci_ssh_cidrs="[\"${ipv4}/32\"]"
    ;;
  close)
    export TF_VAR_ci_ssh_cidrs="[]"
    ;;
  *)
    echo "mode must be open or close" >&2
    exit 1
    ;;
esac

# A full apply would use the root deploy key. This script must not.
unset TF_VAR_admin_ssh_private_key || true

if [[ -z "${RUNNER_TEMP:-}" ]]; then
  echo "RUNNER_TEMP is not set" >&2
  exit 1
fi

plan="${RUNNER_TEMP}/fw-${mode}.tfplan"
plan_json="${RUNNER_TEMP}/fw-${mode}.json"
rm -f "$plan" "$plan_json"
cleanup() {
  rm -f "$plan" "$plan_json"
}
trap cleanup EXIT

terraform -chdir=main plan \
  -input=false \
  -no-color \
  -target=linode_firewall.luanti \
  -out="$plan"
terraform -chdir=main show -json "$plan" >"$plan_json"
python3 scripts/ci-firewall-ssh-only.py \
  "$plan_json" \
  "${ipv4}/32" \
  "$mode" \
  main/terraform.tfvars

# Applying a saved plan does not prompt. The checker already accepted it.
terraform -chdir=main apply -input=false -no-color "$plan"
