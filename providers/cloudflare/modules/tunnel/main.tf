locals {
  hosts     = toset([for r in var.routes : r.host])
  protected = { for hostname, r in var.routes : hostname => r if r.access != null }

  # A protected route lets people in with an email login, machine clients in with a
  # service token, or both.
  logins   = { for hostname, r in local.protected : hostname => r.access if length(concat(r.access.emails, r.access.email_domains)) > 0 }
  services = { for hostname, r in local.protected : hostname => r.access.service_tokens if length(r.access.service_tokens) > 0 }

  service_tokens = toset(flatten(values(local.services)))
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
          service  = "${r.scheme}://${r.origin}:${r.port}"
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
  for_each = local.logins

  account_id = var.account_id
  name       = "${var.name_prefix} ${each.key}"
  decision   = "allow"

  include = concat(
    [for e in each.value.emails : { email = { email = e } }],
    [for d in each.value.email_domains : { email_domain = { domain = d } }],
  )
}

# One token per name, shared by every route that lists it. Clients send its ID and secret
# as the CF-Access-Client-Id and CF-Access-Client-Secret headers.
resource "cloudflare_zero_trust_access_service_token" "this" {
  for_each = local.service_tokens

  account_id = var.account_id
  name       = "${var.name_prefix}-${each.key}"
  duration   = var.service_token_duration
}

# Service tokens only pass a Service Auth (non_identity) policy. Under an allow policy
# Access would send the client to the login page instead.
resource "cloudflare_zero_trust_access_policy" "service" {
  for_each = local.services

  account_id = var.account_id
  name       = "${var.name_prefix} ${each.key} service tokens"
  decision   = "non_identity"

  include = [for t in each.value : { service_token = { token_id = cloudflare_zero_trust_access_service_token.this[t].id } }]
}

resource "cloudflare_zero_trust_access_application" "route" {
  for_each = local.protected

  account_id       = var.account_id
  name             = each.key
  domain           = each.key
  type             = "self_hosted"
  session_duration = var.session_duration

  # Without an email login there is no one to redirect: a request without a valid token
  # gets a 401 at Cloudflare's edge.
  service_auth_401_redirect = contains(keys(local.logins), each.key) ? null : true

  policies = [
    for i, id in concat(
      contains(keys(local.services), each.key) ? [cloudflare_zero_trust_access_policy.service[each.key].id] : [],
      contains(keys(local.logins), each.key) ? [cloudflare_zero_trust_access_policy.route[each.key].id] : [],
    ) : { id = id, precedence = i + 1 }
  ]
}
