output "state_bucket_label" {
  description = "Bucket name for the main root's S3 backend."
  value       = linode_object_storage_bucket.state.label
}

output "state_s3_endpoint_host" {
  description = "Hostname (no scheme) of the state bucket's S3 endpoint. Copy into main/backend.hcl."
  value       = local.state_endpoint_host
}

output "backups_bucket_label" {
  description = "Bucket the game server uploads world tarballs to."
  value       = linode_object_storage_bucket.backups.label
}

output "backups_s3_endpoint_host" {
  description = "Hostname (no scheme) for the backups bucket. Set main's object_storage_endpoint to this."
  value       = local.backups_endpoint_host
}

output "state_access_key" {
  description = "S3 access key for the Terraform backend. Export as AWS_ACCESS_KEY_ID."
  value       = linode_object_storage_key.state.access_key
  sensitive   = true
}

output "state_secret_key" {
  description = "S3 secret key for the Terraform backend. Export as AWS_SECRET_ACCESS_KEY. Shown once; it lives in this root's local state."
  value       = linode_object_storage_key.state.secret_key
  sensitive   = true
}

output "backups_access_key" {
  description = "S3 access key installed on the game server. Export as TF_VAR_backups_access_key."
  value       = linode_object_storage_key.backups.access_key
  sensitive   = true
}

output "backups_secret_key" {
  description = "S3 secret key installed on the game server. Export as TF_VAR_backups_secret_key."
  value       = linode_object_storage_key.backups.secret_key
  sensitive   = true
}

output "backend_config_hcl" {
  description = "Write this to main/backend.hcl before initializing the main root."
  value       = <<-EOT
    bucket                      = "${linode_object_storage_bucket.state.label}"
    key                         = "luanti/terraform.tfstate"
    region                      = "us-east-1"
    use_path_style              = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
    endpoints = {
      s3 = "https://${local.state_endpoint_host}"
    }
  EOT
}
