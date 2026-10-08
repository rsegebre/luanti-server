resource "linode_firewall" "luanti" {
  label           = "${var.instance_label}-fw"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  tags            = ["luanti", "private"]

  # ICMP is not a join path. v4 fragmentation-needed and v6 packet-too-big
  # come from routers that are not the player's address. IPv6 also needs
  # neighbor discovery. Dropping those breaks the path even when the player's
  # prefix is allowlisted.
  inbound {
    label    = "icmp-v4"
    action   = "ACCEPT"
    protocol = "ICMP"
    ipv4     = ["0.0.0.0/0"]
  }

  inbound {
    label    = "icmp-v6"
    action   = "ACCEPT"
    protocol = "ICMP"
    ipv6     = ["::/0"]
  }

  dynamic "inbound" {
    for_each = length(local.player_ipv4) > 0 ? [1] : []
    content {
      label    = "luanti-udp-v4"
      action   = "ACCEPT"
      protocol = "UDP"
      ports    = tostring(var.luanti_port)
      ipv4     = local.player_ipv4
    }
  }

  dynamic "inbound" {
    for_each = length(local.player_ipv6) > 0 ? [1] : []
    content {
      label    = "luanti-udp-v6"
      action   = "ACCEPT"
      protocol = "UDP"
      ports    = tostring(var.luanti_port)
      ipv6     = local.player_ipv6
    }
  }

  # SSH sources are admin_cidrs plus ci_ssh_cidrs. The CI list is empty in
  # committed config. Actions sets it to the runner /32 for one apply, then
  # applies this firewall again with the list empty so the rule does not linger.
  dynamic "inbound" {
    for_each = length(local.admin_ipv4) > 0 ? [1] : []
    content {
      label    = "ssh-v4"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = "22"
      ipv4     = local.admin_ipv4
    }
  }

  dynamic "inbound" {
    for_each = length(local.admin_ipv6) > 0 ? [1] : []
    content {
      label    = "ssh-v6"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = "22"
      ipv6     = local.admin_ipv6
    }
  }

  # Attach here, not via linode_instance.firewall_id. Changing firewall_id
  # forces a new VM; updating these rules does not.
  linodes = [linode_instance.luanti.id]
}
