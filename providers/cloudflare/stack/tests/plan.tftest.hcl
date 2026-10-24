# Runs offline: `terraform test` / `tofu test` from providers/cloudflare/stack.
# Plans the stack against a mocked Cloudflare API and a fixture hybrid inventory.

mock_provider "cloudflare" {
  mock_data "cloudflare_zone" {
    defaults = {
      id      = "023e105f4ecef8ad9ca31a8372d0c353"
      name    = "example.com"
      account = { id = "699d98642c564d2e855e9661899b7252", name = "Mock" }
    }
  }

  mock_resource "cloudflare_zero_trust_tunnel_cloudflared" {
    defaults = { id = "f70ff985-a4ef-4643-bbbc-4a0ed4fc8415" }
  }

  mock_data "cloudflare_zero_trust_tunnel_cloudflared_token" {
    defaults = { token = "mock-tunnel-token" }
  }
}

variables {
  zone                 = "example.com"
  inventory_state_path = "tests/fixtures/hybrid.tfstate"
  routes = {
    "api.example.com" = { host = "oci-main", port = 8080 }
  }
}

run "routes_to_inventory_hosts_plan" {
  command = plan

  assert {
    condition     = module.tunnel.routes["api.example.com"] == { host = "oci-main", service = "http://localhost:8080", protected = false }
    error_message = "The route should reach port 8080 on oci-main through its tunnel."
  }
}

run "account_comes_from_the_zone" {
  command = plan

  assert {
    condition     = module.tunnel.tunnels != null && data.cloudflare_zone.this.account.id == "699d98642c564d2e855e9661899b7252"
    error_message = "With no account_id, the zone's account owns the tunnels."
  }
}

run "apply_exposes_a_token_per_host" {
  command = apply

  assert {
    condition     = keys(output.tunnels) == ["oci-main"] && nonsensitive(output.tunnel_tokens["oci-main"]) == "mock-tunnel-token"
    error_message = "deploy needs one cloudflared token per host."
  }
}

run "unknown_host_fails_the_plan" {
  command = plan

  variables {
    routes = { "api.example.com" = { host = "oci-mian", port = 8080 } }
  }

  expect_failures = [terraform_data.checks]
}

run "missing_inventory_fails_the_plan" {
  command = plan

  variables {
    inventory_state_path = "tests/fixtures/does-not-exist.tfstate"
  }

  expect_failures = [terraform_data.checks]
}

run "hostnames_outside_the_zone_fail_the_plan" {
  command = plan

  variables {
    routes = { "api.example.org" = { host = "oci-main", port = 8080 } }
  }

  expect_failures = [terraform_data.checks]
}

# On a container platform, cloudflared runs as a service next to the apps and reaches each
# one by its service name.
run "routes_to_a_platform_reach_the_app_by_name" {
  command = plan

  variables {
    routes = {
      "api.example.com" = { host = "northflank-main", app = "api", port = 8080 }
      "www.example.com" = { host = "oci-main", app = "web", port = 3000 }
    }
  }

  assert {
    condition     = module.tunnel.routes["api.example.com"] == { host = "northflank-main", service = "http://api:8080", protected = false }
    error_message = "A route to a platform should go to <app>:<port>."
  }

  assert {
    condition     = module.tunnel.routes["www.example.com"].service == "http://localhost:3000"
    error_message = "On a VM, app changes nothing: cloudflared runs with host networking."
  }
}

run "routes_to_a_platform_need_the_app" {
  command = plan

  variables {
    routes = { "api.example.com" = { host = "northflank-main", port = 8080 } }
  }

  expect_failures = [terraform_data.checks]
}

run "platforms_without_cloudflared_get_no_routes" {
  command = plan

  variables {
    routes = { "api.example.com" = { host = "cloud-run-main", app = "api", port = 8080 } }
  }

  expect_failures = [terraform_data.checks]
}
