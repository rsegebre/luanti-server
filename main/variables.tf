variable "zone_name" {
  type        = string
  description = "Cloudflare DNS zone to look up by name. No other records in the zone are managed."
  default     = "rsegebre.com"
}

variable "hostname" {
  type        = string
  description = "Fully qualified name players type into the Luanti client. DNS-only A and AAAA records are created for this name."
  default     = "luanti.rsegebre.com"
}

variable "region" {
  type        = string
  description = "Linode region for the game VM and its world volume."
  default     = "us-west"
}

variable "instance_type" {
  type        = string
  description = "Linode plan. g6-standard-2 is the Shared 4 GB plan."
  default     = "g6-standard-2"
}

variable "instance_label" {
  type        = string
  description = "Linode display label and short hostname used in first-boot cloud-init. metadata.user_data is ignored after create, so changing this label does not replace the VM. The hostname on an already-booted VM is not rewritten. The world volume is separate."
  default     = "luanti"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", var.instance_label))
    error_message = "Instance label must be a short lowercase hostname."
  }
}

variable "image" {
  type        = string
  description = "Linode image slug. Ubuntu 24.04 ships cloud-init with the Akamai datasource."
  default     = "linode/ubuntu24.04"
}

variable "backups_enabled" {
  type        = bool
  description = "Enroll the VM in Linode Backups. This is a whole-disk add-on, separate from the nightly world tarball."
  default     = true
}

variable "disk_encryption" {
  type        = string
  description = "Linode disk encryption policy for the VM."
  default     = "enabled"

  validation {
    condition     = contains(["enabled", "disabled"], var.disk_encryption)
    error_message = "disk_encryption must be enabled or disabled."
  }
}

variable "swap_size" {
  type        = number
  description = "Swap disk size in MB on the VM's root disk."
  default     = 512
}

variable "world_volume_label" {
  type        = string
  description = "Block Storage volume label. The bootstrap script looks the device up by this name. metadata.user_data is ignored after create, so renaming it does not replace the VM and does not rewrite the device path on an already-booted host. The volume label itself updates in place."
  default     = "luanti-world"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", var.world_volume_label))
    error_message = "Volume label must be lowercase letters, digits, and hyphens."
  }
}

variable "world_volume_size_gb" {
  type        = number
  description = "World volume size in GB. Linode's minimum is 10, which is about $1/month. Growing it later is an in-place resize."
  default     = 10

  validation {
    condition     = var.world_volume_size_gb >= 10
    error_message = "Linode Block Storage volumes are at least 10 GB."
  }
}

variable "admin_ssh_public_keys" {
  type        = list(string)
  description = "Owner SSH public keys for root and the sudo user. Written by the config push. Also included in the initial Linode authorized_keys; that attribute is ignored after create so editing this list does not replace the VM."
  default     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAPCZTXQUV6iaNHp7lhyTjRB/j/ivLtZKZhN6aPo5Lhv robertosegebre13@gmail.com"]

  validation {
    condition = alltrue([
      for key in var.admin_ssh_public_keys :
      can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/=]+", key))
    ])
    error_message = "Each entry must be an SSH public key."
  }
}

variable "admin_ssh_private_key" {
  type        = string
  description = "Private key used to push config over SSH. Leave null to use ssh-agent. GitHub Actions sets this to the deploy key. Prefer the environment over a file."
  default     = null
  sensitive   = true
  nullable    = true
}

variable "deploy_ssh_public_keys" {
  type        = list(string)
  description = "Public halves of CI deploy keys. Not secret. The private half stays in the DEPLOY_SSH_PRIVATE_KEY Actions secret. Empty until the owner generates a key. Same install path as admin_ssh_public_keys, so rotation does not replace the VM."
  default     = []

  validation {
    condition = alltrue([
      for key in var.deploy_ssh_public_keys :
      can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/=]+", key))
    ])
    error_message = "Each deploy key must be an SSH public key."
  }
}

variable "ci_ssh_cidrs" {
  type        = list(string)
  description = "Extra SSH host routes for this apply only. GitHub Actions sets the runner /32, then applies again with this empty. Leave it empty in tfvars."
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.ci_ssh_cidrs :
      can(cidrhost(cidr, 0)) && (
        (!strcontains(cidr, ":") && endswith(cidr, "/32")) ||
        (strcontains(cidr, ":") && endswith(cidr, "/128"))
      )
    ])
    error_message = "ci_ssh_cidrs must be individual hosts (/32 or /128). Leave it empty outside CI."
  }
}

variable "sudo_user" {
  type        = string
  description = "Non-root sudo account created on first boot and embedded in cloud-init. metadata.user_data is ignored after create, so renaming it does not replace the VM and does not create a new account on the existing host."
  default     = "luantiadmin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.sudo_user))
    error_message = "sudo_user must be a short lowercase Linux username."
  }
}

variable "admin_cidrs" {
  type        = list(string)
  description = "IPv4 and IPv6 CIDRs allowed to SSH. Use a /32 for a home IPv4 address."
  default     = ["73.92.174.251/32", "2601:647:5b00:66a0::/64"]

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for cidr in var.admin_cidrs : can(cidrhost(cidr, 0))])
    error_message = "admin_cidrs must be a non-empty list of CIDR prefixes."
  }
}

variable "player_cidrs" {
  type        = list(string)
  description = "IPv4 and IPv6 CIDRs allowed to reach Luanti UDP. Residential IPv6 should be the stable /64, not a single rotating address."
  default     = ["73.92.174.251/32", "2601:647:5b00:66a0::/64"]

  validation {
    condition     = length(var.player_cidrs) > 0 && alltrue([for cidr in var.player_cidrs : can(cidrhost(cidr, 0))])
    error_message = "player_cidrs must be a non-empty list of CIDR prefixes."
  }
}

variable "admin_player_name" {
  type        = string
  description = "Luanti account that receives admin privileges. Always included in the join allowlist. Set with the name setting so the engine treats this player as admin. This server uses rss1989."
  default     = "rss1989"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,20}$", var.admin_player_name))
    error_message = "Admin player name must be 1-20 characters: letters, digits, underscore, hyphen."
  }
}

variable "allowed_player_names" {
  type        = list(string)
  description = "Extra Luanti names allowed to join. The admin name is added automatically. Names are case-sensitive."
  default     = []

  validation {
    condition = alltrue([
      for name in var.allowed_player_names : can(regex("^[A-Za-z0-9_-]{1,20}$", name))
    ])
    error_message = "Player names must be 1-20 characters: letters, digits, underscore, hyphen."
  }
}

variable "luanti_image" {
  type        = string
  description = "Official Luanti server image. Pinned to the 5.17.0 stable tag, not :latest."
  default     = "ghcr.io/luanti-org/luanti:5.17.0"
}

variable "luanti_port" {
  type        = number
  description = "UDP port published on the host and set in minetest.conf."
  default     = 30000
}

variable "game_id" {
  type        = string
  description = "Luanti game id, which is the directory name under games/. minetest_game, voxelibre, or mineclonia."
  default     = "minetest_game"

  validation {
    condition     = can(regex("^[a-z0-9_]+$", var.game_id))
    error_message = "game_id must be lowercase letters, digits, and underscores."
  }
}

variable "game_git_url" {
  type        = string
  description = "Git URL of the game. Minetest Game is not bundled in the official image."
  default     = "https://github.com/luanti-org/minetest_game.git"
}

variable "game_git_ref" {
  type        = string
  description = "Git commit (or tag) to check out. Minetest Game is a rolling tree, so this is pinned to a commit."
  default     = "c42e4d0c0ff9d27ff7b9b308c3cfc14098dd3a0f"
}

variable "world_name" {
  type        = string
  description = "World directory name. Changing it starts a new world and leaves the old directory on the volume."
  default     = "world"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.world_name))
    error_message = "world_name must be letters, digits, underscore, or hyphen."
  }
}

variable "server_name" {
  type        = string
  description = "Name shown to connected players. The server is not announced, and server_address is intentionally unset."
  default     = "Private"

  validation {
    condition     = !strcontains(var.server_name, "\n") && !strcontains(var.server_name, "#") && !strcontains(var.server_name, "\"")
    error_message = "server_name must be a single line without a hash or a double quote."
  }
}

variable "motd" {
  type        = string
  description = "Message shown when a player joins."
  default     = "Private server for invited players. Ask the owner if you need an account."

  validation {
    condition     = !strcontains(var.motd, "\n") && !strcontains(var.motd, "#") && !strcontains(var.motd, "\"")
    error_message = "motd must be a single line without a hash or a double quote."
  }
}

variable "max_users" {
  type        = number
  description = "Maximum simultaneous players."
  default     = 8
}

variable "default_privs" {
  type        = string
  description = "Privileges granted to a newly created non-admin account. interact and shout are enough to play; admin privs are not included."
  default     = "interact,shout"
}

variable "creative_mode" {
  type        = bool
  description = "World creative mode."
  default     = false
}

variable "enable_damage" {
  type        = bool
  description = "World damage."
  default     = true
}

variable "publish_ipv6" {
  type        = bool
  description = "Also publish the Luanti UDP port on the host's IPv6 address."
  default     = true
}

variable "backup_upload_enabled" {
  type        = bool
  description = "After the local tarball is written, copy it to the backups bucket."
  default     = true
}

variable "backup_retention_count" {
  type        = number
  description = "How many world tarballs to keep locally and in the bucket."
  default     = 7

  validation {
    condition     = var.backup_retention_count >= 1 && var.backup_retention_count <= 90
    error_message = "Keep between 1 and 90 backups."
  }
}

variable "backup_calendar" {
  type        = string
  description = "systemd OnCalendar for the world backup, evaluated in UTC (the VM clock is set to UTC). Default is 08:15 UTC, about 01:15 America/Los_Angeles."
  default     = "*-*-* 08:15:00"
}

variable "backups_bucket_label" {
  type        = string
  description = "Must match the backups bucket created by the bootstrap root."
  default     = "rsegebre-luanti-backups"
}

variable "object_storage_endpoint" {
  type        = string
  description = "S3 hostname for the backups bucket, without https://. Override with bootstrap's backups_s3_endpoint_host if it differs."
  default     = "us-sea-1.linodeobjects.com"

  validation {
    condition     = !strcontains(var.object_storage_endpoint, "://") && !strcontains(var.object_storage_endpoint, "/")
    error_message = "object_storage_endpoint must be a hostname, not a URL."
  }
}

variable "backups_access_key" {
  type        = string
  description = "Access key from bootstrap output backups_access_key. Set with TF_VAR_backups_access_key."
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9+/=._-]{8,128}$", var.backups_access_key))
    error_message = "backups_access_key must be one line of letters, digits, and +/=._- characters."
  }
}

variable "backups_secret_key" {
  type        = string
  description = "Secret key from bootstrap output backups_secret_key. Set with TF_VAR_backups_secret_key."
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9+/=._-]{8,256}$", var.backups_secret_key))
    error_message = "backups_secret_key must be one line of letters, digits, and +/=._- characters."
  }
}

variable "push_config_over_ssh" {
  type        = bool
  description = "After the VM exists, SSH from this machine and install Luanti config. Apply must be able to reach TCP 22 from an admin CIDR. Firewall-only changes do not need SSH when this resource's inputs are unchanged."
  default     = true
}
