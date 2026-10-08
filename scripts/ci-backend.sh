#!/usr/bin/env bash
# Write main/backend.hcl from GitHub Actions variables. No secrets are written
# or printed. Credentials stay in AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
set -euo pipefail

: "${TF_STATE_BUCKET:?Set repository variable TF_STATE_BUCKET from bootstrap output state_bucket_label}"
: "${TF_STATE_ENDPOINT_HOST:?Set repository variable TF_STATE_ENDPOINT_HOST from bootstrap output state_s3_endpoint_host}"
: "${AWS_ACCESS_KEY_ID:?Set secret TF_STATE_ACCESS_KEY}"
: "${AWS_SECRET_ACCESS_KEY:?Set secret TF_STATE_SECRET_KEY}"

if [[ "$TF_STATE_ENDPOINT_HOST" == *"://"* || "$TF_STATE_ENDPOINT_HOST" == */* ]]; then
  echo "TF_STATE_ENDPOINT_HOST must be a hostname, without https:// or a path" >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${root}/main/backend.hcl"
umask 077
cat >"$dest" <<EOF
bucket                      = "${TF_STATE_BUCKET}"
key                         = "luanti/terraform.tfstate"
region                      = "us-east-1"
use_path_style              = true
skip_credentials_validation = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_s3_checksum            = true
endpoints = {
  s3 = "https://${TF_STATE_ENDPOINT_HOST}"
}
EOF
echo "wrote ${dest}"
