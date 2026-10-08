resource "linode_instance" "luanti" {
  label            = var.instance_label
  region           = var.region
  type             = var.instance_type
  image            = var.image
  authorized_keys  = concat(var.admin_ssh_public_keys, var.deploy_ssh_public_keys)
  backups_enabled  = var.backups_enabled
  disk_encryption  = var.disk_encryption
  swap_size        = var.swap_size
  booted           = true
  watchdog_enabled = true
  tags             = ["luanti", "private"]

  # user_data is ForceNew. Keep player allowlists, game settings, and SSH
  # public keys out of it. Those are pushed over SSH (see runtime.tf).
  # authorized_keys is also ForceNew. Ignore it after create so adding or
  # rotating a key updates the files on disk instead of replacing the VM.
  # The first create still writes this list into /root/.ssh/authorized_keys.
  # metadata.user_data is ignored after create for the same reason: the
  # bootstrap script is embedded in cloud-init, and editing it must not
  # replace the VM. A later create, if the instance is replaced for another
  # reason, still receives the current user_data. Cloud-init does not re-run
  # on the existing host.
  metadata {
    user_data = base64encode(local.cloud_init)
  }

  lifecycle {
    ignore_changes = [
      authorized_keys,
      metadata[0].user_data,
    ]
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
