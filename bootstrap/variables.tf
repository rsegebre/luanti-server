variable "object_storage_region" {
  type        = string
  description = "Linode region for both Object Storage buckets. Fremont (us-west) has no Object Storage; Seattle (us-sea) is the nearest generally available cluster."
  default     = "us-sea"

  validation {
    condition     = var.object_storage_region != "us-west"
    error_message = "us-west (Fremont) does not offer Object Storage. Use us-sea or another Object Storage region."
  }
}

variable "state_bucket_label" {
  type        = string
  description = "Bucket that stores the main root's Terraform state. Must match main/backend.hcl."
  default     = "rsegebre-luanti-tfstate"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.state_bucket_label))
    error_message = "Bucket label must be 3-63 characters, lowercase letters, digits, and hyphens."
  }
}

variable "backups_bucket_label" {
  type        = string
  description = "Bucket for nightly world tarballs. The game server's key is limited to this bucket."
  default     = "rsegebre-luanti-backups"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.backups_bucket_label))
    error_message = "Bucket label must be 3-63 characters, lowercase letters, digits, and hyphens."
  }
}

variable "state_key_label" {
  type        = string
  description = "Display label for the Object Storage key used by the Terraform S3 backend."
  default     = "luanti-terraform-state"
}

variable "backups_key_label" {
  type        = string
  description = "Display label for the Object Storage key installed on the game server."
  default     = "luanti-world-backups"
}
