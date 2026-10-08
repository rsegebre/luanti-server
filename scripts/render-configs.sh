#!/usr/bin/env bash
# Render the shipped templates with Terraform's templatefile, offline.
# Writes cloud-init.yaml, minetest.conf, world.mt, init.lua, and mod.conf
# into the directory given as the first argument. No providers and no backend.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${1:?output directory}"
mkdir -p "$dest"

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

cat >"$work/main.tf" <<'EOF'
variable "root" {
  type = string
}

locals {
  names = ["admin"]

  cloud_init = templatefile("${var.root}/main/templates/cloud-init.yaml.tftpl", {
    hostname_short = "luanti"
    fqdn           = "luanti.rsegebre.com"
    sudo_user      = "luantiadmin"
    volume_label   = "luanti-world"
    host_bootstrap  = file("${var.root}/main/files/host-bootstrap.sh")
  })

  minetest_conf = templatefile("${var.root}/main/templates/minetest.conf.tftpl", {
    server_name   = "Private"
    motd          = "Private server for invited players. Ask the owner if you need an account."
    port          = 30000
    admin_name    = "admin"
    default_privs = "interact,shout"
    max_users     = 8
    creative_mode = false
    enable_damage = true
  })

  world_mt = templatefile("${var.root}/main/templates/world.mt.tftpl", {
    game_id       = "minetest_game"
    world_name    = "world"
    creative_mode = false
    enable_damage = true
  })

  allowlist_init = templatefile("${var.root}/main/templates/player_allowlist_init.lua.tftpl", {
    names = local.names
  })

  mod_conf = <<-EOT
    name = player_allowlist
    description = Reject players who are not on the private allowlist
    author = rsegebre
  EOT
}

output "cloud_init" {
  value = local.cloud_init
}

output "minetest_conf" {
  value = local.minetest_conf
}

output "world_mt" {
  value = local.world_mt
}

output "allowlist_init" {
  value = local.allowlist_init
}

output "mod_conf" {
  value = local.mod_conf
}
EOF

terraform -chdir="$work" init -input=false >/dev/null
terraform -chdir="$work" apply -auto-approve -input=false -var="root=${root}" >/dev/null
terraform -chdir="$work" output -raw cloud_init >"$dest/cloud-init.yaml"
terraform -chdir="$work" output -raw minetest_conf >"$dest/minetest.conf"
terraform -chdir="$work" output -raw world_mt >"$dest/world.mt"
terraform -chdir="$work" output -raw allowlist_init >"$dest/init.lua"
terraform -chdir="$work" output -raw mod_conf >"$dest/mod.conf"
