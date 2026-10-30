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

  mock_resource "cloudflare_account_token" {
    defaults = { id = "ed17574386854bf78a67040be0a770b0", value = "mock-r2-token" }
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

run "r2_buckets_get_a_key_of_their_own" {
  command = apply

  variables {
    name_prefix = "shop"
    buckets     = { results = { location = "weur" } }
    # Terraform's mocks can't fill in the permission groups the stack looks up.
    r2_permission_group_id = "2efd5506f9c8494dacb1fa10a3e7d5b6"
  }

  assert {
    condition     = cloudflare_r2_bucket.this["results"].name == "shop-results" && cloudflare_r2_bucket.this["results"].location == "weur"
    error_message = "An R2 bucket is <name_prefix>-<name> in the zone's account."
  }

  assert {
    condition = (
      [for g in one(cloudflare_account_token.r2["results"].policies).permission_groups : g.id] == ["2efd5506f9c8494dacb1fa10a3e7d5b6"] &&
      jsondecode(one(cloudflare_account_token.r2["results"].policies).resources) == { "com.cloudflare.edge.r2.bucket.699d98642c564d2e855e9661899b7252_default_shop-results" = "*" }
    )
    error_message = "The bucket's token reads, writes and lists objects in that bucket only."
  }

  assert {
    condition = output.buckets == [{
      provider = "cloudflare", name = "results", bucket = "shop-results",
      endpoint = "https://699d98642c564d2e855e9661899b7252.r2.cloudflarestorage.com", region = "auto"
    }]
    error_message = "The storage contract: provider, name, bucket, S3 endpoint and region."
  }

  assert {
    condition = nonsensitive(output.bucket_keys["cloudflare-results"]) == {
      access_key_id     = "ed17574386854bf78a67040be0a770b0"
      secret_access_key = sha256("mock-r2-token")
    }
    error_message = "R2 takes the token's ID as the access key and the SHA-256 of its value as the secret."
  }
}

run "no_buckets_need_no_token_permissions" {
  command = plan

  assert {
    condition     = length(data.cloudflare_account_api_token_permission_groups_list.all) == 0 && output.buckets == []
    error_message = "Without buckets the stack doesn't look up token permissions, so the tunnel token needs none."
  }
}

run "r2_names_cloudflare_refuses_fail" {
  command = plan

  variables {
    buckets = { "results-" = {} }
  }

  expect_failures = [terraform_data.r2_checks]
}

run "a_route_without_a_host_goes_to_the_default_host" {
  command = plan

  variables {
    default_host = "oci-main"
    routes       = { "api.example.com" = { port = 8080 } }
  }

  assert {
    condition     = module.tunnel.routes["api.example.com"].host == "oci-main"
    error_message = "A route that names no host uses default_host."
  }
}

run "a_route_without_a_host_and_no_default_fails" {
  command = plan

  variables {
    routes = { "api.example.com" = { port = 8080 } }
  }

  expect_failures = [terraform_data.checks]
}
