resource "linode_instance" "luanti" {
  label            = var.instance_label
  region           = var.region
  type             = var.instance_type
  image            = var.image
  authorized_keys  = var.admin_ssh_public_keys
  backups_enabled  = var.backups_enabled
  disk_encryption  = var.disk_encryption
  swap_size        = var.swap_size
  booted           = true
  watchdog_enabled = true
  tags             = ["luanti", "private"]

  # user_data is ForceNew. Keep player allowlists and game settings out of it.
  # Those are pushed over SSH (see runtime.tf) so a friend can be added without
  # replacing the VM. This cloud-init only hardens the host and mounts the volume.
  metadata {
    user_data = base64encode(local.cloud_init)
  }

  timeouts {
    create = "30m"
    update = "30m"
  }
}

resource "linode_volume" "world" {
  label     = var.world_volume_label
  region    = var.region
  size      = var.world_volume_size_gb
  linode_id = linode_instance.luanti.id
  tags      = ["luanti", "private"]

  # The map lives here. Refuse to destroy it as part of a casual terraform destroy.
  # Remove this block only when you really mean to delete the world.
  lifecycle {
    prevent_destroy = true
  }
}
