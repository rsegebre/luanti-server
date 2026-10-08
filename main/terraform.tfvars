# Non-secret inputs. main/terraform.tfvars is committed (the repo is private)
# and is what GitHub Actions plans and applies. Other *.tfvars files are gitignored.
# Secrets are NOT in this file. Export them before a local plan:
#   TF_VAR_backups_access_key
#   TF_VAR_backups_secret_key
# Leave admin_ssh_private_key unset to use ssh-agent.
# Leave ci_ssh_cidrs unset. Actions sets it for one apply, then clears it.

zone_name      = "rsegebre.com"
hostname       = "luanti.rsegebre.com"
region         = "us-west"
instance_type  = "g6-standard-2"
instance_label = "luanti"
image          = "linode/ubuntu24.04"

backups_enabled = true
disk_encryption = "enabled"
swap_size       = 512

world_volume_label   = "luanti-world"
world_volume_size_gb = 10

admin_ssh_public_keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAPCZTXQUV6iaNHp7lhyTjRB/j/ivLtZKZhN6aPo5Lhv robertosegebre13@gmail.com",
]
# Public half of the GitHub Actions deploy key. Generate it before the first
# apply and put the private half in the production environment secret
# DEPLOY_SSH_PRIVATE_KEY. Leave this empty until then; the apply job refuses
# to run with an empty list. To rotate, add the new key beside the old one,
# apply, switch the secret, then remove the old key and apply again.
deploy_ssh_public_keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlxZvhA/SRQOfBOVU8BxyKfHN00/GKKj7BN/rDTder4 github-actions-luanti",
]
# admin_ssh_private_key = null
# ci_ssh_cidrs = []
sudo_user = "luantiadmin"

# Home IPv4 is a single address. Residential IPv6 (Comcast and similar) keeps
# a stable /64 for the household and rotates the interface ID, so the prefix
# is allowlisted instead of one temporary address. Put extra friends AFTER the
# first entry of each family. scripts/update-allowlist-ip.sh replaces the first
# IPv4 and the first IPv6 prefix.
admin_cidrs = [
  "73.92.174.251/32",
  "2601:647:5b00:66a0::/64",
]
player_cidrs = [
  "73.92.174.251/32",
  "2601:647:5b00:66a0::/64",
]

admin_player_name    = "rss1989"
allowed_player_names = []

luanti_image = "ghcr.io/luanti-org/luanti:5.17.0"
luanti_port  = 30000

# Swap the game later by changing these three and applying. That does not
# convert an existing world. VoxeLibre: game_id voxelibre,
# https://github.com/VoxeLibre/VoxeLibre.git. Mineclonia: game_id mineclonia,
# https://codeberg.org/mineclonia/mineclonia.git.
game_id      = "minetest_game"
game_git_url = "https://github.com/luanti-org/minetest_game.git"
game_git_ref = "c42e4d0c0ff9d27ff7b9b308c3cfc14098dd3a0f"
world_name   = "world"

# Mods and modpacks installed into the world's worldmods directory on apply.
# git_ref is a full 40-character commit SHA. Adding or removing one restarts
# Luanti and does not replace the VM or the volume. List dependencies as their
# own entries. See "Adding a mod" in the README.
# mods = [
#   {
#     name    = "anvil"
#     git_url = "https://github.com/minetest-mods/anvil.git"
#     git_ref = "9bc6f63af822269c16db69cc0f8e4710207aa1a7"
#     # subdir  = "anvil" # only when the mod is not at the repository root
#     # trusted = false   # true appends the name to secure.trusted_mods
#   },
# ]
mods = []

server_name   = "Private"
motd          = "Private server for invited players. Ask the owner if you need an account."
max_users     = 8
default_privs = "interact,shout"
creative_mode = false
enable_damage = true
publish_ipv6  = true

backup_upload_enabled  = true
backup_retention_count = 7
backup_calendar        = "*-*-* 08:15:00"
backups_bucket_label   = "rsegebre-luanti-backups"
# Hostname only, no https://. Use bootstrap output backups_s3_endpoint_host
# if it is not this Seattle E1 name.
object_storage_endpoint = "us-sea-1.linodeobjects.com"

# Actions applies this from a runner and opens SSH for that run only.
# A laptop apply has to be on an admin CIDR. Leave ci_ssh_cidrs unset.
push_config_over_ssh = true
