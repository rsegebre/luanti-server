output "hostname" {
  description = "Name to enter in the Luanti client."
  value       = var.hostname
}

output "ipv4_address" {
  description = "Public IPv4 address of the VM."
  value       = local.public_ipv4
}

output "ipv6_address" {
  description = "Public IPv6 address published as the AAAA record. Confirm it answers before relying on it; Linode reports the SLAAC address."
  value       = local.public_ipv6
}

output "luanti_port" {
  description = "UDP port."
  value       = var.luanti_port
}

output "ssh_command" {
  description = "SSH command from an admin CIDR."
  value       = "ssh root@${local.public_ipv4}"
}

output "allowed_player_names" {
  description = "Names the join allowlist will accept, including the admin."
  value       = local.allowed_player_names
}

output "world_volume_id" {
  description = "Block Storage volume that holds the world. It is protected from terraform destroy."
  value       = linode_volume.world.id
}

output "instance_id" {
  description = "Linode instance id."
  value       = linode_instance.luanti.id
}

output "instance_label" {
  description = "Linode display label."
  value       = linode_instance.luanti.label
}

output "firewall_id" {
  description = "Cloud Firewall id."
  value       = linode_firewall.luanti.id
}

output "cloud_init_bytes" {
  description = "Decoded cloud-init size. Linode user_data must stay well under 64 KiB. metadata.user_data is ignored after create, so a size change does not replace the VM."
  value       = length(local.cloud_init)
}
