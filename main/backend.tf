# Partial backend. Bucket and endpoint come from bootstrap output, written to
# backend.hcl (gitignored). Credentials come from AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY (the state key, not the game-server key).
#
#   terraform init -backend-config=backend.hcl
#
# `terraform init -backend=false` works without that file and is what CI/review uses.
# State locking is intentionally off: Linode Object Storage does not provide
# DynamoDB locks, and conditional-write lockfiles are not reliable on the E1 endpoint.
terraform {
  backend "s3" {
    key = "luanti/terraform.tfstate"
  }
}
