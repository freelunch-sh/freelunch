locals {
  hosts     = toset([for r in var.routes : r.host])
  protected = { for hostname, r in var.routes : hostname => r if r.access != null }
}

# One remotely managed tunnel per host. cloudflared on the host only needs the token;
# the ingress rules live here.
resource "cloudflare_zero_trust_tunnel_cloudflared" "host" {
  for_each = local.hosts

  account_id = var.account_id
  name       = "${var.name_prefix}-${each.key}"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "host" {
  for_each = local.hosts

  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.host[each.key].id

  config = {
    ingress = concat(
      [
        for hostname, r in var.routes : {
          hostname = hostname
          service  = "${r.scheme}://localhost:${r.port}"
        } if r.host == each.key
      ],
      # cloudflared requires a catch-all rule last.
      [{ hostname = null, service = "http_status:404" }],
    )
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "host" {
  for_each = local.hosts

  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.host[each.key].id
}

resource "cloudflare_dns_record" "route" {
  for_each = var.routes

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.host[each.value.host].id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "freelunch: tunnel to ${each.value.host}"
}

resource "cloudflare_zero_trust_access_policy" "route" {
  for_each = local.protected

  account_id = var.account_id
  name       = "${var.name_prefix} ${each.key}"
  decision   = "allow"

  include = concat(
    [for e in each.value.access.emails : { email = { email = e } }],
    [for d in each.value.access.email_domains : { email_domain = { domain = d } }],
  )
}

resource "cloudflare_zero_trust_access_application" "route" {
  for_each = local.protected

  account_id       = var.account_id
  name             = each.key
  domain           = each.key
  type             = "self_hosted"
  session_duration = var.session_duration

  policies = [{ id = cloudflare_zero_trust_access_policy.route[each.key].id, precedence = 1 }]
}
