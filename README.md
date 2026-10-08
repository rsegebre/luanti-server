# Private Luanti server

Terraform for a small Luanti server (the project formerly called Minetest) on one Linode, at `luanti.rsegebre.com`. It is for a couple of friends connecting from home. The DNS name resolves, but the server is not on the public server list, the firewall drops everyone else, and an in-game allowlist rejects unknown player names.

Nothing in this repo is applied for you. After review, run `terraform plan` and read it before any apply. Do not point these roots at a production token until that plan looks right.

## What a plan creates

Bootstrap (`bootstrap/`, local state):

- Two private Object Storage buckets in Seattle (`us-sea`): one for Terraform state, one for world tarballs
- Two limited keys. The state key can only touch the state bucket. The backup key can only touch the backups bucket

Main (`main/`, S3 backend):

- A Linode `g6-standard-2` (Shared 4 GB) in Fremont (`us-west`), Ubuntu 24.04, disk encryption on, Linode Backups on
- A 10 GB Block Storage volume for the world, attached to that VM
- A Cloud Firewall attached to the VM: inbound default DROP, outbound ACCEPT, UDP 30000 and SSH 22 only from the allowlists, plus ICMP
- Cloudflare DNS-only A and AAAA records for `luanti.rsegebre.com`
- A config push over SSH that installs the container, the game, and the allowlist. That push runs on apply, not during plan

## Cost

Akamai's North America list prices, checked October 2026. Confirm them on the pricing page before apply. Tax is extra.

| Piece | List price |
| --- | --- |
| Linode 4 GB (`g6-standard-2`), includes 4 TB outbound | $24 / month |
| Linode Backups add-on for that plan | $5 / month |
| Block Storage, 10 GB (the minimum) | $1 / month |
| Object Storage | see below |
| **Typical total** | **about $30–$35 / month** |

The public price page lists Object Storage at $0.02/GB-month, with the first 1 TB of outbound included. Two small buckets (state plus a handful of world tarballs) are well under a dollar at that rate. Some accounts still show the older $5/month Object Storage subscription, which includes 250 GB and adds 1 TB to the transfer pool. Either way this stays far under $100/month. Extra block storage is $0.10/GB-month. Transfer past the included pool is $0.005/GB in Fremont and Seattle.

Linode Backups are tied to the VM. Replacing the VM discards those backups. The nightly tarball on the volume, and the copy in the backups bucket, are the copies that survive a rebuild.

## Layout

```
bootstrap/          local-state root: buckets and keys
main/               S3-backend root: VM, firewall, DNS, config push
main/files/         scripts and systemd units installed on the VM
main/templates/     cloud-init, minetest.conf, allowlist mod
scripts/            local helpers (IP update, validate, smoke test)
```

## Prerequisites

- Terraform >= 1.10 (1.16 is fine)
- A Linode personal access token (`LINODE_TOKEN`) that can manage instances, firewalls, volumes, and Object Storage
- A Cloudflare API token (`CLOUDFLARE_API_TOKEN`), account-owned (`cfat_…`), with zone DNS edit on `rsegebre.com` only
- The SSH private key matching the public key in `admin_ssh_public_keys`, loaded in `ssh-agent` when you apply with the config push turned on
- `git`, `curl`, and `python3` on the machine that runs the helper script

No tokens are committed. Real `terraform.tfvars`, `backend.hcl`, and state files are gitignored.

## First-time setup

Run this from a checkout of the repo. The bootstrap root uses local state. That state file contains both Object Storage secret keys. Back it up somewhere private and do not commit it. Linode shows each secret key only once; if you lose the state file, create new keys.

1. Export the Linode token and create the buckets:

   ```bash
   export LINODE_TOKEN=...
   cd bootstrap
   terraform init
   terraform plan
   terraform apply
   ```

2. Write the backend file and export the keys. The secret outputs are sensitive, so `-raw` is required:

   ```bash
   terraform output -raw backend_config_hcl > ../main/backend.hcl
   export AWS_ACCESS_KEY_ID="$(terraform output -raw state_access_key)"
   export AWS_SECRET_ACCESS_KEY="$(terraform output -raw state_secret_key)"
   export TF_VAR_backups_access_key="$(terraform output -raw backups_access_key)"
   export TF_VAR_backups_secret_key="$(terraform output -raw backups_secret_key)"
   terraform output -raw state_s3_endpoint_host
   terraform output -raw backups_s3_endpoint_host
   ```

3. If either hostname differs from `us-sea-1.linodeobjects.com`, edit `main/backend.hcl` (the state host) and set `object_storage_endpoint` in `main/terraform.tfvars` (the backups host, no `https://`). New buckets sometimes land on a different endpoint than the example.

4. Copy the example inputs and review them:

   ```bash
   cd ../main
   cp terraform.tfvars.example terraform.tfvars
   ```

   Every input is in that example. The backup keys stay in the environment, not in the file.

5. Initialize the remote backend, then plan:

   ```bash
   export CLOUDFLARE_API_TOKEN=...
   terraform init -backend-config=backend.hcl
   terraform plan
   ```

   `terraform init -backend=false` skips the backend. Use that for a review machine that does not have the state keys. `terraform validate` does not need real backup keys. A plan does.

6. Apply from a network that is already in `admin_cidrs`, with the SSH key in the agent. The firewall is created before the SSH push, but the first boot still has to accept your connection.

   If you are not on an allowlisted network, set `push_config_over_ssh = false`, apply, then from home set it back to `true` and apply again. The second apply only uploads config. It does not rebuild the VM.

Optional: `TF_VAR_admin_ssh_private_key` instead of ssh-agent. Prefer the agent. The private key is sensitive.

## Day to day

Changing a player CIDR or an admin CIDR updates the firewall in place. It does not SSH and does not replace the VM.

Changing the allowlist, game pin, port, or backup settings re-runs the SSH push and restarts Luanti. The world directory is kept.

Changing `admin_ssh_public_keys`, `sudo_user`, `world_volume_label`, or anything else inside cloud-init replaces the VM. `user_data` and `authorized_keys` are ForceNew in the Linode provider. The world volume is reattached and is not formatted again if it already has a filesystem. Linode Backups of the old VM are deleted with it.

`terraform destroy` will not delete the volume until you remove `prevent_destroy` from `linode_volume.world`. Do that only when you mean to delete the world.

There is no state lock. Do not run two applies at once. Linode Object Storage has no DynamoDB lock, and conditional-write lockfiles are unreliable on the E1 endpoint. Bucket versioning is off because turning it on needs the access key, and a limited key that references the bucket creates a dependency cycle.

## Adding a player

Three separate gates, and a friend needs all three:

1. Their IP, in `player_cidrs` (and in `admin_cidrs` too, if they should SSH). Append it after the first entry so `scripts/update-allowlist-ip.sh` keeps treating the first IPv4 and the first IPv6 prefix as your house. Apply. That is a firewall change only.
2. Their Luanti name, in `allowed_player_names`. Names are case-sensitive, 1–20 characters, letters, digits, `_`, and `-`. The admin name is always included. Apply. That uploads a new allowlist and restarts the server. It does not replace the VM.
3. A password, created by you over SSH before they connect. Players cannot register themselves.

   ```bash
   ssh root@luanti.rsegebre.com
   luanti-setpassword theirname
   ```

   The command prompts twice, writes a one-shot file the allowlist mod consumes, and the mod stores a password hash in the world auth database. The password is not in Terraform, shell history, or the backup tarball. `disallow_empty_password` is on, and `default_privs` is `interact,shout`.

   `admin_player_name` (default `admin`) also receives the usual admin privileges the first time you set that password. Set the admin password the same way before you play.

## Updating a home IP

Residential IPv6 here rotates inside `2601:647:5b00:66a0::/64`. The firewall allows that whole prefix so a new temporary address still works. One `/64` is still one household, not the public internet. The name allowlist and the password are what stop someone else on that prefix.

When the IPv4 changes, or you want to refresh the prefix from the machine you are sitting at:

```bash
scripts/update-allowlist-ip.sh
cd main
terraform plan
terraform apply
```

The script calls `api.ipify.org` for the current public address, stores IPv4 as a `/32` and IPv6 as a `/64`, and rewrites the first entry of each family in both `admin_cidrs` and `player_cidrs`. Extra entries stay. `--only player` or `--only admin`, `--skip-ipv6`, `--ipv4`, `--ipv6`, and `--dry-run` are available. Update `admin_cidrs` whenever your own SSH address changes, or the next apply cannot connect.

## Connecting

In the Luanti client, add a server:

- Address: `luanti.rsegebre.com`
- Port: `30000`
- Name: the allowlisted name
- Password: the one set with `luanti-setpassword`

The client should be on an address covered by `player_cidrs`. Direct connection only. The server does not appear in the public server list (`server_announce = false`, and `server_address` / `server_url` are left unset on purpose).

## Restoring a world

Backups run at 08:15 UTC (about 01:15 in Pacific time) via `luanti-backup.timer`. The server stops, a `world-STAMP.tar.gz` is written to `/var/lib/luanti/backups` on the volume, old copies past `backup_retention_count` are deleted, and the new tarball is copied to `s3://<backups-bucket>/world-backups/` when `backup_upload_enabled` is true. The server starts again after. Local and remote copies are both rotated.

On the VM:

```bash
luanti-restore /var/lib/luanti/backups/world-STAMP.tar.gz
luanti-restore s3:world-STAMP.tar.gz
```

The archive has to contain a top-level directory named the same as `world_name` (default `world`). The current world is moved aside to `world.pre-restore-STAMP`. If extraction fails, that directory is moved back. A successful restore leaves the aside copy on the volume until you delete it.

Linode Backups, in Cloud Manager, are a whole-disk snapshot of the VM. Use those for the root disk. Use the tarball for the world, especially after a VM replacement, because those snapshots go away with the instance.

## Game

The default game is Minetest Game, checked out at a pinned commit because the official image does not ship a game. To switch later, change `game_id`, `game_git_url`, and `game_git_ref`, then apply. Examples are in `terraform.tfvars.example` (VoxeLibre, Mineclonia). An existing world is not converted. Point `world_name` at a new directory or restore a matching backup.

The server is `ghcr.io/luanti-org/luanti:5.17.0`, not `:latest`, under systemd (`Restart=always`), so it comes back after a crash or a reboot. World data is on the volume, mounted at `/var/lib/luanti`.

## Design notes

These differ from a literal reading of "everything in Fremont" or "config only via cloud-init", with reasons:

- **Object Storage is in Seattle (`us-sea`), not Fremont.** Fremont has no Object Storage. Seattle's E1 endpoint is the nearest generally available cluster. The VM stays in `us-west`.
- **The world is on a 10 GB volume.** Cloud-init `user_data` and `authorized_keys` force a new VM when they change. A world on the root disk would be destroyed with it. The volume has `prevent_destroy` set. Ten gigabytes is Linode's minimum, about $1/month, so the total is about $30–$35 rather than $34 with no volume.
- **ICMP from anywhere is allowed.** Path MTU discovery and IPv6 neighbor discovery come from routers, not from the player's address. Dropping them breaks the path even for an allowlisted player. ICMP is not a way to join.
- **Allowlists are pushed over SSH, not baked into cloud-init.** Putting them in `user_data` would replace the VM on every friend added. The first boot still uses Linode Metadata user data (cloud-init). Akamai's current docs say Metadata is on in every region, including Fremont, and Ubuntu 24.04 ships the datasource. This repo could not query the live regions API. If create-time API rejects `user_data` in `us-west`, stop and add a StackScript. Do not ignore that error. After the first boot, `cloud-init status` should be `done`.
- **The join allowlist is a small mod in this repo** (`player_allowlist`), generated from `allowed_player_names`. It uses `core.register_on_prejoinplayer`. A third-party mod would be another supply-chain dependency for a list we already render.
- **SSH is key-only for root, and there is a sudo user `luantiadmin`.** Password authentication and keyboard-interactive are off. Root's password is locked. Unattended upgrades install security updates and do not reboot automatically. Schedule a reboot yourself when a kernel update needs one.
- **IPv6 allowlist entries are a `/64`.** Documented above.

DNS is looked up by zone name. Only the A and AAAA for `luanti.rsegebre.com` are managed, both with `proxied = false`. The Cloudflare proxy does not carry this UDP traffic.

## Checks

```bash
scripts/validate.sh
```

That runs `terraform fmt -check`, `terraform init -backend=false && terraform validate` in both roots, shellcheck, and `cloud-init schema` on the rendered user-data. It does not call Linode or Cloudflare.

`scripts/smoke-luanti.sh` pulls `ghcr.io/luanti-org/luanti:5.17.0`, renders the config with Terraform, and checks that the server starts, does not announce, loads the allowlist, accepts a password drop, and rejects a name that is not on the list. It needs Docker and outbound access to ghcr.io and GitHub. It does not call Linode or Cloudflare.

## Credentials you must supply

| Name | Where | Purpose |
| --- | --- | --- |
| `LINODE_TOKEN` | environment | Bootstrap and main Linode provider |
| `CLOUDFLARE_API_TOKEN` | environment | DNS edits on `rsegebre.com` (`cfat_…`) |
| `AWS_ACCESS_KEY_ID` | environment, from bootstrap `state_access_key` | Main S3 backend |
| `AWS_SECRET_ACCESS_KEY` | environment, from bootstrap `state_secret_key` | Main S3 backend |
| `TF_VAR_backups_access_key` | environment, from bootstrap `backups_access_key` | World-backup uploads |
| `TF_VAR_backups_secret_key` | environment, from bootstrap `backups_secret_key` | World-backup uploads |
| SSH private key | ssh-agent, or `TF_VAR_admin_ssh_private_key` | Config push |
| `main/terraform.tfvars` | local file, copied from the example | Every non-secret input |

The backup secret is written into `/etc/luanti/rclone.conf` on the VM and is therefore also in the main state file. That state lives in the private state bucket, and the game server's key cannot read it. Keep the bootstrap state file private too.

## Worth a careful look

- The hostname resolves publicly. Privacy is the firewall, the name allowlist, and passwords, not a secret DNS name.
- A `/64` is a household prefix. Anyone who can use an address in that prefix can open a UDP session. They still need an allowlisted name and a password.
- The first apply's SSH step must come from an `admin_cidrs` address. A plan from anywhere is fine. An apply with `push_config_over_ssh = true` from somewhere else will create the VM and then fail the provisioner.
- Confirm the AAAA record is a host address. The provider's `ipv6` attribute is the SLAAC address; the config strips a trailing prefix length if one is present.
- Replacing the VM (new SSH key, renamed sudo user, edited cloud-init) drops Linode Backups for the old instance. Take a world tarball first if you are not sure the nightly job has run.
- Do not run two applies at the same time. There is no state lock.
- `scripts/update-allowlist-ip.sh` replaces the first IPv4 and first IPv6 entry only. Put your house first and friends after it.
