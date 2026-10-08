resource "terraform_data" "runtime_config" {
  count = var.push_config_over_ssh ? 1 : 0

  # Re-runs the SSH push when config changes. This does not replace the VM.
  # Firewall CIDR edits are not in this map, so an IP update does not need SSH.
  # mods is folded into server_env (a MODS_SHA256 line) only when the list is
  # non-empty, so mods = [] does not by itself replace this resource.
  triggers_replace = {
    minetest_conf       = local.minetest_conf
    world_mt            = local.world_mt
    allowlist_init      = local.allowlist_init
    mod_conf            = local.mod_conf
    server_env          = local.server_env
    backup_timer        = local.backup_timer
    backups_secret_hash = local.backups_secret_hash
    backups_access_hash = local.backups_access_hash
    authorized_keys     = local.managed_authorized_keys
    object_endpoint     = var.object_storage_endpoint
    install_script      = filesha256("${path.module}/files/luanti-install.sh")
    run_script          = filesha256("${path.module}/files/luanti-run.sh")
    backup_script       = filesha256("${path.module}/files/luanti-backup.sh")
    restore_script      = filesha256("${path.module}/files/luanti-restore.sh")
    setpassword_script  = filesha256("${path.module}/files/luanti-setpassword.sh")
    unit_service        = filesha256("${path.module}/files/luanti.service")
    unit_backup         = filesha256("${path.module}/files/luanti-backup.service")
  }

  depends_on = [
    linode_firewall.luanti,
    linode_volume.world,
  ]

  connection {
    type        = "ssh"
    user        = "root"
    host        = local.public_ipv4
    timeout     = "20m"
    private_key = var.admin_ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      # cloud-init status --wait exits non-zero when first boot ended in
      # error. Print the long status and continue. The push is idempotent
      # and is what fixes a host after that error. Do not fail the apply.
      "cloud-init status --wait || cloud-init status --long || true",
      "mkdir -p /etc/luanti /usr/local/sbin /var/lib/luanti/password-drop /var/lib/luanti/backups",
      "mkdir -p /var/lib/luanti/data/.minetest/worlds/${var.world_name}/worldmods/player_allowlist",
      "install -d -m 0700 /root/.ssh",
      "install -d -m 0700 -o ${var.sudo_user} -g ${var.sudo_user} /home/${var.sudo_user}/.ssh",
    ]
  }

  provisioner "file" {
    content     = local.managed_authorized_keys
    destination = "/root/.ssh/authorized_keys"
  }

  provisioner "file" {
    content     = local.managed_authorized_keys
    destination = "/home/${var.sudo_user}/.ssh/authorized_keys"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 0600 /root/.ssh/authorized_keys /home/${var.sudo_user}/.ssh/authorized_keys",
      "chown root:root /root/.ssh/authorized_keys",
      "chown ${var.sudo_user}:${var.sudo_user} /home/${var.sudo_user}/.ssh/authorized_keys",
    ]
  }

  provisioner "file" {
    content     = local.minetest_conf
    destination = "/etc/luanti/minetest.conf"
  }

  provisioner "file" {
    content     = local.server_env
    destination = "/etc/luanti/server.env"
  }

  provisioner "file" {
    content     = local.rclone_conf
    destination = "/etc/luanti/rclone.conf"
  }

  provisioner "file" {
    content     = local.world_mt
    destination = "/var/lib/luanti/data/.minetest/worlds/${var.world_name}/world.mt"
  }

  provisioner "file" {
    content     = local.mod_conf
    destination = "/var/lib/luanti/data/.minetest/worlds/${var.world_name}/worldmods/player_allowlist/mod.conf"
  }

  provisioner "file" {
    content     = local.allowlist_init
    destination = "/var/lib/luanti/data/.minetest/worlds/${var.world_name}/worldmods/player_allowlist/init.lua"
  }

  provisioner "file" {
    content     = local.backup_timer
    destination = "/etc/systemd/system/luanti-backup.timer"
  }

  provisioner "file" {
    content     = local.mods_manifest
    destination = "/var/lib/luanti/mods.manifest"
  }

  provisioner "file" {
    source      = "${path.module}/files/luanti-mods.sh"
    destination = "/usr/local/sbin/luanti-mods"
  }

  provisioner "file" {
    source      = "${path.module}/files/luanti-install.sh"
    destination = "/usr/local/sbin/luanti-install"
  }

  provisioner "file" {
    source      = "${path.module}/files/luanti-run.sh"
    destination = "/usr/local/sbin/luanti-run"
  }

  provisioner "file" {
    source      = "${path.module}/files/luanti-backup.sh"
    destination = "/usr/local/sbin/luanti-backup"
  }

  provisioner "file" {
    source      = "${path.module}/files/luanti-restore.sh"
    destination = "/usr/local/sbin/luanti-restore"
  }

  provisioner "file" {
    source      = "${path.module}/files/luanti-setpassword.sh"
    destination = "/usr/local/sbin/luanti-setpassword"
  }

  provisioner "file" {
    source      = "${path.module}/files/luanti.service"
    destination = "/etc/systemd/system/luanti.service"
  }

  provisioner "file" {
    source      = "${path.module}/files/luanti-backup.service"
    destination = "/etc/systemd/system/luanti-backup.service"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 0755 /usr/local/sbin/luanti-install /usr/local/sbin/luanti-mods /usr/local/sbin/luanti-run /usr/local/sbin/luanti-backup /usr/local/sbin/luanti-restore /usr/local/sbin/luanti-setpassword",
      "chmod 0644 /etc/luanti/minetest.conf /etc/luanti/server.env /etc/systemd/system/luanti.service /etc/systemd/system/luanti-backup.service /etc/systemd/system/luanti-backup.timer /var/lib/luanti/mods.manifest",
      "chmod 0600 /etc/luanti/rclone.conf",
      "/usr/local/sbin/luanti-mods",
      "/usr/local/sbin/luanti-install",
    ]
  }
}
