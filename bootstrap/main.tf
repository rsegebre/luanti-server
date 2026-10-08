resource "linode_object_storage_bucket" "state" {
  region = var.object_storage_region
  label  = var.state_bucket_label
  acl    = "private"
}

resource "linode_object_storage_bucket" "backups" {
  region = var.object_storage_region
  label  = var.backups_bucket_label
  acl    = "private"
}

# Limited to the state bucket. This key is only for the operator's Terraform
# backend. It cannot read world backups, and it is never copied onto the VM.
resource "linode_object_storage_key" "state" {
  label = var.state_key_label

  bucket_access {
    bucket_name = linode_object_storage_bucket.state.label
    region      = linode_object_storage_bucket.state.region
    permissions = "read_write"
  }
}

# Limited to the backups bucket. The game server uses this key to upload
# world tarballs. It cannot read Terraform state.
resource "linode_object_storage_key" "backups" {
  label = var.backups_key_label

  bucket_access {
    bucket_name = linode_object_storage_bucket.backups.label
    region      = linode_object_storage_bucket.backups.region
    permissions = "read_write"
  }
}

locals {
  state_endpoint_host   = trimprefix(trimprefix(linode_object_storage_bucket.state.s3_endpoint, "https://"), "http://")
  backups_endpoint_host = trimprefix(trimprefix(linode_object_storage_bucket.backups.s3_endpoint, "https://"), "http://")
}
