# Runs offline: `terraform test` / `tofu test` from providers/cloudflare/modules/tunnel.

mock_provider "cloudflare" {
  mock_resource "cloudflare_zero_trust_tunnel_cloudflared" {
    defaults = { id = "f70ff985-a4ef-4643-bbbc-4a0ed4fc8415" }
  }

  mock_data "cloudflare_zero_trust_tunnel_cloudflared_token" {
    defaults = { token = "mock-tunnel-token" }
  }

  mock_resource "cloudflare_zero_trust_access_service_token" {
    defaults = {
      id            = "3537a672-e4d8-4d89-aab9-26cb622918a1"
      client_id     = "mock-client-id.access"
      client_secret = "mock-client-secret"
    }
  }
}

variables {
  account_id = "699d98642c564d2e855e9661899b7252"
  zone_id    = "023e105f4ecef8ad9ca31a8372d0c353"

  routes = {
    "api.example.com"    = { host = "oci-main", port = 8080 }
    "admin.example.com"  = { host = "oci-main", port = 9000, access = { emails = ["me@example.com"] } }
    "status.example.com" = { host = "gcp-micro", port = 3001, scheme = "https" }
  }
}

run "one_remotely_managed_tunnel_per_host" {
  command = plan

  assert {
    condition     = keys(cloudflare_zero_trust_tunnel_cloudflared.host) == ["gcp-micro", "oci-main"]
    error_message = "Routes on the same host should share one tunnel."
  }

  assert {
    condition = (
      cloudflare_zero_trust_tunnel_cloudflared.host["oci-main"].name == "freelunch-oci-main" &&
      cloudflare_zero_trust_tunnel_cloudflared.host["oci-main"].config_src == "cloudflare"
    )
    error_message = "Tunnels are named <prefix>-<host> and configured from Cloudflare, so the host only needs a token."
  }
}

run "ingress_maps_each_hostname_to_a_local_port" {
  command = plan

  assert {
    condition = (
      [for r in cloudflare_zero_trust_tunnel_cloudflared_config.host["oci-main"].config.ingress : r.service] ==
      ["http://localhost:9000", "http://localhost:8080", "http_status:404"]
    )
    error_message = "Each route on the host should forward to localhost:<port>, followed by the catch-all."
  }

  assert {
    condition = (
      [for r in cloudflare_zero_trust_tunnel_cloudflared_config.host["oci-main"].config.ingress : r.hostname if r.hostname != null] ==
      ["admin.example.com", "api.example.com"] &&
      cloudflare_zero_trust_tunnel_cloudflared_config.host["oci-main"].config.ingress[2].hostname == null
    )
    error_message = "The catch-all rule must come last and have no hostname."
  }

  assert {
    condition     = [for r in cloudflare_zero_trust_tunnel_cloudflared_config.host["gcp-micro"].config.ingress : r.service] == ["https://localhost:3001", "http_status:404"]
    error_message = "A host's tunnel should only carry that host's routes, with the chosen scheme."
  }
}

# On a container platform, cloudflared is a service of its own, so the route names the
# app's service instead of localhost.
run "ingress_can_reach_another_service" {
  command = plan

  variables {
    routes = { "api.example.com" = { host = "northflank-main", port = 8080, origin = "api" } }
  }

  assert {
    condition     = [for r in cloudflare_zero_trust_tunnel_cloudflared_config.host["northflank-main"].config.ingress : r.service] == ["http://api:8080", "http_status:404"]
    error_message = "origin should replace localhost in the ingress rule."
  }

  assert {
    condition     = output.routes["api.example.com"].service == "http://api:8080"
    error_message = "The routes output should show the service cloudflared reaches."
  }
}

run "dns_records_are_proxied_cnames_to_the_tunnel" {
  command = apply

  assert {
    condition = alltrue([
      for r in cloudflare_dns_record.route :
      r.type == "CNAME" && r.proxied && r.ttl == 1 && r.content == "f70ff985-a4ef-4643-bbbc-4a0ed4fc8415.cfargotunnel.com"
    ])
    error_message = "Every hostname needs a proxied CNAME to <tunnel id>.cfargotunnel.com."
  }

  assert {
    condition     = keys(cloudflare_dns_record.route) == ["admin.example.com", "api.example.com", "status.example.com"]
    error_message = "One DNS record per route."
  }

  assert {
    condition     = output.urls == ["https://admin.example.com", "https://api.example.com", "https://status.example.com"]
    error_message = "urls should list every route over HTTPS."
  }
}

run "tokens_are_exposed_per_host" {
  command = apply

  assert {
    condition     = keys(output.tunnels) == ["gcp-micro", "oci-main"]
    error_message = "tunnels should map host -> tunnel ID."
  }

  assert {
    condition     = nonsensitive(output.tunnel_tokens["oci-main"]) == "mock-tunnel-token"
    error_message = "deploy reads the cloudflared token per host from tunnel_tokens."
  }
}

run "access_protects_only_routes_that_ask_for_it" {
  command = plan

  assert {
    condition     = keys(cloudflare_zero_trust_access_application.route) == ["admin.example.com"]
    error_message = "Only routes with access set get an Access application."
  }

  assert {
    condition = (
      cloudflare_zero_trust_access_application.route["admin.example.com"].type == "self_hosted" &&
      cloudflare_zero_trust_access_application.route["admin.example.com"].domain == "admin.example.com"
    )
    error_message = "The Access application should cover the route's hostname."
  }

  assert {
    condition = (
      cloudflare_zero_trust_access_policy.route["admin.example.com"].decision == "allow" &&
      one(cloudflare_zero_trust_access_policy.route["admin.example.com"].include).email.email == "me@example.com"
    )
    error_message = "The policy should allow the listed emails."
  }

  assert {
    condition     = output.routes["admin.example.com"].protected && !output.routes["api.example.com"].protected
    error_message = "routes should say which hostnames are behind Access."
  }
}

run "email_domains_are_allowed_too" {
  command = plan

  variables {
    routes = {
      "team.example.com" = { host = "oci-main", port = 8080, access = { email_domains = ["example.com"] } }
    }
  }

  assert {
    condition     = one(cloudflare_zero_trust_access_policy.route["team.example.com"].include).email_domain.domain == "example.com"
    error_message = "email_domains should become email_domain include rules."
  }
}

run "service_tokens_get_a_service_auth_policy" {
  command = apply

  variables {
    routes = {
      "api.example.com"   = { host = "oci-main", port = 8080, access = { service_tokens = ["backend"] } }
      "admin.example.com" = { host = "oci-main", port = 9000, access = { emails = ["me@example.com"], service_tokens = ["backend", "ci"] } }
    }
  }

  assert {
    condition = (
      keys(cloudflare_zero_trust_access_service_token.this) == ["backend", "ci"] &&
      cloudflare_zero_trust_access_service_token.this["backend"].name == "freelunch-backend"
    )
    error_message = "Each token name should become one service token, shared by the routes that list it."
  }

  assert {
    condition = (
      cloudflare_zero_trust_access_policy.service["api.example.com"].decision == "non_identity" &&
      one(cloudflare_zero_trust_access_policy.service["api.example.com"].include).service_token.token_id == "3537a672-e4d8-4d89-aab9-26cb622918a1"
    )
    error_message = "Service tokens need a Service Auth (non_identity) policy that includes them; an allow policy would ask for a login."
  }

  assert {
    condition     = keys(cloudflare_zero_trust_access_policy.route) == ["admin.example.com"]
    error_message = "A route with only service tokens should get no email login policy."
  }

  assert {
    condition = (
      length(cloudflare_zero_trust_access_application.route["api.example.com"].policies) == 1 &&
      cloudflare_zero_trust_access_application.route["api.example.com"].service_auth_401_redirect == true
    )
    error_message = "A token-only route should answer 401 instead of redirecting to a login page."
  }

  assert {
    condition = (
      [for p in cloudflare_zero_trust_access_application.route["admin.example.com"].policies : p.id] == [
        cloudflare_zero_trust_access_policy.service["admin.example.com"].id,
        cloudflare_zero_trust_access_policy.route["admin.example.com"].id,
      ] &&
      [for p in cloudflare_zero_trust_access_application.route["admin.example.com"].policies : p.precedence] == [1, 2] &&
      cloudflare_zero_trust_access_application.route["admin.example.com"].service_auth_401_redirect != true
    )
    error_message = "A route with logins and tokens should get both policies, and keep the login page."
  }

  assert {
    condition     = nonsensitive(output.service_tokens["backend"].client_id) == "mock-client-id.access" && nonsensitive(output.service_tokens["backend"].client_secret) == "mock-client-secret"
    error_message = "service_tokens should expose each token's client ID and secret."
  }
}

run "hostnames_must_be_full_names" {
  command = plan

  variables {
    routes = { "API" = { host = "oci-main", port = 8080 } }
  }

  expect_failures = [var.routes]
}

run "ports_must_be_valid" {
  command = plan

  variables {
    routes = { "api.example.com" = { host = "oci-main", port = 70000 } }
  }

  expect_failures = [var.routes]
}

run "access_needs_someone_to_allow" {
  command = plan

  variables {
    routes = { "api.example.com" = { host = "oci-main", port = 8080, access = {} } }
  }

  expect_failures = [var.routes]
}

run "service_token_names_must_be_simple" {
  command = plan

  variables {
    routes = { "api.example.com" = { host = "oci-main", port = 8080, access = { service_tokens = ["My Token"] } } }
  }

  expect_failures = [var.routes]
}

run "origins_must_be_host_names" {
  command = plan

  variables {
    routes = { "api.example.com" = { host = "northflank-main", port = 8080, origin = "http://api" } }
  }

  expect_failures = [var.routes]
}
