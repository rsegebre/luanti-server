locals {
  allowed_player_names = distinct(concat([var.admin_player_name], var.allowed_player_names))

  player_ipv4 = [for cidr in var.player_cidrs : cidr if !strcontains(cidr, ":")]
  player_ipv6 = [for cidr in var.player_cidrs : cidr if strcontains(cidr, ":")]
  # ci_ssh_cidrs is empty except during the GitHub Actions apply that pushes config.
  ssh_cidrs  = distinct(concat(var.admin_cidrs, var.ci_ssh_cidrs))
  admin_ipv4 = [for cidr in local.ssh_cidrs : cidr if !strcontains(cidr, ":")]
  admin_ipv6 = [for cidr in local.ssh_cidrs : cidr if strcontains(cidr, ":")]

  managed_authorized_keys = "${join("\n", concat(var.admin_ssh_public_keys, var.deploy_ssh_public_keys))}\n"

  public_ipv4 = one([
    for addr in tolist(linode_instance.luanti.ipv4) : addr
    if !startswith(addr, "192.168.")
  ])
  public_ipv6 = split("/", linode_instance.luanti.ipv6)[0]

  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    hostname_short = var.instance_label
    fqdn           = var.hostname
    sudo_user      = var.sudo_user
    volume_label   = var.world_volume_label
    host_bootstrap = file("${path.module}/files/host-bootstrap.sh")
  })

  # player_allowlist stays first. Trusted mod names follow, in list order.
  # With no trusted mods this is the single token the template already used.
  trusted_mods = join(",", concat(
    ["player_allowlist"],
    [for mod in var.mods : mod.name if mod.trusted],
  ))

  minetest_conf = templatefile("${path.module}/templates/minetest.conf.tftpl", {
    server_name   = var.server_name
    motd          = var.motd
    port          = var.luanti_port
    admin_name    = var.admin_player_name
    default_privs = var.default_privs
    max_users     = var.max_users
    creative_mode = var.creative_mode
    enable_damage = var.enable_damage
    trusted_mods  = local.trusted_mods
  })

  world_mt = templatefile("${path.module}/templates/world.mt.tftpl", {
    game_id       = var.game_id
    world_name    = var.world_name
    creative_mode = var.creative_mode
    enable_damage = var.enable_damage
  })

  allowlist_init = templatefile("${path.module}/templates/player_allowlist_init.lua.tftpl", {
    names = local.allowed_player_names
  })

  mod_conf = <<-EOT
    name = player_allowlist
    description = Reject players who are not on the private allowlist
    author = rsegebre
  EOT

  # Kept byte-for-byte when mods is empty so the config push is not replaced.
  server_env_base = <<-EOT
    LUANTI_IMAGE="${var.luanti_image}"
    LUANTI_PORT="${var.luanti_port}"
    GAME_ID="${var.game_id}"
    GAME_GIT_URL="${var.game_git_url}"
    GAME_GIT_REF="${var.game_git_ref}"
    WORLD_NAME="${var.world_name}"
    PUBLISH_IPV6="${var.publish_ipv6}"
    BACKUP_UPLOAD="${var.backup_upload_enabled}"
    BACKUP_RETENTION="${var.backup_retention_count}"
    BACKUP_BUCKET="${var.backups_bucket_label}"
  EOT

  # One manifest line per mod: name, https URL, commit, subdir (`.` is the repo root).
  mods_lines = [
    for mod in var.mods :
    "${mod.name} ${mod.git_url} ${mod.git_ref} ${mod.subdir == "" ? "." : mod.subdir}"
  ]

  mods_manifest = join("\n", concat(["# name git_url git_ref subdir"], local.mods_lines, [""]))

  # Included in server_env only when at least one mod is listed. The hash covers
  # the manifest and the installer script, so a script fix re-runs the push
  # while mods are in use. An empty list leaves server_env equal to server_env_base.
  mods_sha = sha256("${join("\n", local.mods_lines)}\n${filesha256("${path.module}/files/luanti-mods.sh")}")

  server_env = length(var.mods) == 0 ? local.server_env_base : "${local.server_env_base}MODS_SHA256=${local.mods_sha}\n"

  rclone_conf = templatefile("${path.module}/templates/rclone.conf.tftpl", {
    access_key = var.backups_access_key
    secret_key = var.backups_secret_key
    endpoint   = var.object_storage_endpoint
  })

  backup_timer = templatefile("${path.module}/templates/luanti-backup.timer.tftpl", {
    calendar = var.backup_calendar
  })

  # nonsensitive() so a key rotation shows up as a hash change in the plan
  # without printing the key. The key is high-entropy, so the hash is not reversible.
  backups_secret_hash = nonsensitive(sha256(var.backups_secret_key))
  backups_access_hash = nonsensitive(sha256(var.backups_access_key))
}
