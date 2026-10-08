data "cloudflare_zones" "dns" {
  name   = var.zone_name
  status = "active"
}

locals {
  zone_id = one([
    for zone in data.cloudflare_zones.dns.result : zone.id
    if zone.name == var.zone_name
  ])
}

resource "cloudflare_dns_record" "luanti_a" {
  zone_id = local.zone_id
  name    = var.hostname
  type    = "A"
  content = local.public_ipv4
  ttl     = 300
  proxied = false
  comment = "Luanti private server. DNS-only: the Cloudflare proxy does not carry UDP."
}

resource "cloudflare_dns_record" "luanti_aaaa" {
  zone_id = local.zone_id
  name    = var.hostname
  type    = "AAAA"
  content = local.public_ipv6
  ttl     = 300
  proxied = false
  comment = "Luanti private server IPv6. DNS-only: the Cloudflare proxy does not carry UDP."
}
