# Runs offline: `terraform test` / `tofu test` from deploy/. Uses fixture state files.

variables {
  config_dir           = "tests/fixtures"
  inventory_state_path = "tests/fixtures/hybrid.tfstate"
  tunnel_state_path    = "tests/fixtures/cloudflare.tfstate"

  apps = {
    api = { host = "oci-main", compose = "compose.yaml", env_file = "api.env" }
  }
}

run "apps_and_tunnel_resolve_to_one_target_per_host" {
  command = plan

  assert {
    condition     = keys(output.targets) == ["oci-main"]
    error_message = "One target per host that has apps or a tunnel."
  }

  assert {
    condition = (
      output.targets["oci-main"].address == "203.0.113.10" &&
      output.targets["oci-main"].user == "ubuntu" &&
      output.targets["oci-main"].provider == "oci" &&
      output.targets["oci-main"].arch == "arm64"
    )
    error_message = "SSH address, user and architecture come from the inventory."
  }

  assert {
    condition = (
      endswith(output.targets["oci-main"].apps.api.compose, "/deploy/tests/fixtures/compose.yaml") &&
      startswith(output.targets["oci-main"].apps.api.compose, "/") &&
      endswith(output.targets["oci-main"].apps.api.env_file, "/deploy/tests/fixtures/api.env")
    )
    error_message = "Paths are resolved against config_dir and made absolute."
  }

  assert {
    condition     = output.targets["oci-main"].tunnel && output.targets["oci-main"].urls == tolist(["https://api.example.com"])
    error_message = "The host's tunnel and public URLs come from the cloudflare stack."
  }

  assert {
    condition     = nonsensitive(output.tunnel_tokens["oci-main"]) == "mock-tunnel-token"
    error_message = "The tunnel token is handed to deploy for the host."
  }
}

run "relative_paths_may_leave_the_config_dir" {
  command = plan

  variables {
    config_dir = "tests/fixtures/project"
    apps       = { api = { host = "oci-main", compose = "../compose.yaml" } }
  }

  assert {
    condition     = endswith(output.targets["oci-main"].apps.api.compose, "/deploy/tests/fixtures/compose.yaml") && output.targets["oci-main"].apps.api.env_file == null
    error_message = "../compose.yaml from .freelunch/ should point at the project's compose file."
  }
}

run "private_only_hosts_use_the_private_ip" {
  command = plan

  variables {
    apps = { worker = { host = "azure-arm", compose = "compose.yaml" } }
  }

  assert {
    condition     = output.targets["azure-arm"].address == "10.0.1.4" && output.targets["azure-arm"].user == "azureuser"
    error_message = "A host without a public IP is reached by its private IP (over Tailscale or a VPN)."
  }

  assert {
    condition     = keys(output.targets) == ["azure-arm", "oci-main"] && length(output.targets["oci-main"].apps) == 0
    error_message = "A host with only a tunnel still gets a target, so cloudflared runs there."
  }
}

run "host_overrides_change_the_address" {
  command = plan

  variables {
    hosts = { oci-main = { address = "freelunch-oci-main" } }
  }

  assert {
    condition     = output.targets["oci-main"].address == "freelunch-oci-main" && output.targets["oci-main"].user == "ubuntu"
    error_message = "hosts.<name>.address replaces the inventory address, e.g. with a Tailscale name."
  }
}

run "hosts_outside_the_inventory_need_an_address" {
  command = plan

  variables {
    tunnel_state_path = null
    hosts             = { box = { address = "192.0.2.50", user = "deploy" } }
    apps              = { api = { host = "box", compose = "compose.yaml" } }
  }

  assert {
    condition = (
      keys(output.targets) == ["box"] &&
      output.targets.box.address == "192.0.2.50" &&
      output.targets.box.user == "deploy" &&
      output.targets.box.provider == null &&
      !output.targets.box.tunnel
    )
    error_message = "Any SSH host works when hosts gives its address and user."
  }
}

run "no_cloudflare_stack_means_no_tunnels" {
  command = plan

  variables {
    tunnel_state_path = null
  }

  assert {
    condition     = !output.targets["oci-main"].tunnel && length(nonsensitive(output.tunnel_tokens)) == 0
    error_message = "Without the cloudflare stack there is nothing to hand to cloudflared."
  }
}

run "unknown_host_fails" {
  command = plan

  variables {
    apps = { api = { host = "oci-mian", compose = "compose.yaml" } }
  }

  expect_failures = [output.targets]
}

run "missing_compose_file_fails" {
  command = plan

  variables {
    apps = { api = { host = "oci-main", compose = "nope.yaml" } }
  }

  expect_failures = [output.targets]
}

run "missing_env_file_fails" {
  command = plan

  variables {
    apps = { api = { host = "oci-main", compose = "compose.yaml", env_file = "nope.env" } }
  }

  expect_failures = [output.targets]
}

run "cloudflared_is_a_reserved_name" {
  command = plan

  variables {
    apps = { cloudflared = { host = "oci-main", compose = "compose.yaml" } }
  }

  expect_failures = [var.apps]
}

run "registry_password_must_come_from_an_env_var" {
  command = plan

  variables {
    registries = { "ghcr.io" = { username = "me", password_env = "ghp_not-a-variable-name" } }
  }

  expect_failures = [var.registries]
}

# Container platforms --------------------------------------------------------------------

run "apps_on_a_platform_become_services" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = "tests/fixtures/platform/cloudflare.tfstate"
    apps                 = { api = { host = "northflank-main", compose = "api.yaml", env_file = "../api.env" } }
  }

  assert {
    condition = (
      output.targets["northflank-main"].kind == "platform" &&
      output.targets["northflank-main"].address == null &&
      output.targets["northflank-main"].provider == "northflank" &&
      output.targets["northflank-main"].arch == "amd64" &&
      output.targets["northflank-main"].tunnel &&
      output.targets["northflank-main"].urls == tolist(["https://api.example.com"])
    )
    error_message = "A platform target has no SSH address, and gets cloudflared when it has a tunnel."
  }

  assert {
    condition     = endswith(output.targets["northflank-main"].apps.api.env_file, "/deploy/tests/fixtures/api.env")
    error_message = "The app's env_file is resolved like on a host."
  }

  assert {
    condition = (
      output.platforms["northflank-main"].provider == "northflank" &&
      output.platforms["northflank-main"].id == "freelunch" &&
      output.platforms["northflank-main"].size == "nf-compute-20"
    )
    error_message = "The platform plan carries the project and the plan from the inventory."
  }

  assert {
    condition = jsonencode(output.platforms["northflank-main"].services.api) == jsonencode({
      image       = "ghcr.io/me/api:1.4.2"
      command     = "serve --port 8080 --name \"my api\""
      entrypoint  = null
      environment = { LOG_LEVEL = "info", WORKERS = "2" }
      ports       = [8080, 9090]
      volumes     = []
      healthcheck = { cmd = "wget -qO- http://127.0.0.1:8080/health", initial_delay = 90, interval = 15, timeout = 5, retries = 6 }
    })
    error_message = "The service takes image, command, environment, ports and healthcheck from the Compose file."
  }
}

run "compose_files_in_other_shapes" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { worker = { host = "northflank-main", compose = "list-env.yaml" } }
  }

  assert {
    condition = jsonencode(output.platforms["northflank-main"].services.worker) == jsonencode({
      image       = "traefik/whoami"
      command     = null
      entrypoint  = "/whoami"
      environment = { MODE = "worker", URL = "https://example.com/?a=b" }
      ports       = []
      volumes     = []
      healthcheck = { cmd = "/bin/sh -c \"curl -f http://localhost/ || exit 1\"", initial_delay = 1, interval = 30, timeout = 30, retries = 3 }
    })
    error_message = "A list environment, a string entrypoint and a CMD-SHELL test (as a string) carry over too, with Docker's defaults."
  }

  assert {
    condition     = !output.targets["northflank-main"].tunnel
    error_message = "No tunnel without the cloudflare stack."
  }
}

run "platform_apps_run_one_container" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "two-services.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "named_volumes_become_volumes_on_the_platform" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "named-volumes.yaml" } }
  }

  assert {
    condition = jsonencode(output.platforms["northflank-main"].services.api.volumes) == jsonencode([
      { id = "api-results", mounts = ["/var/lib/results", "/srv/results"] },
      { id = "api-cache-dir", mounts = ["/cache"] },
    ])
    error_message = "Each named volume becomes <app>-<volume>, mounted wherever the service mounts it, in short or long syntax."
  }

  assert {
    condition     = output.platforms["northflank-main"].volume_size == 4096
    error_message = "The volume size comes from the platform stack."
  }
}

run "platforms_dont_have_the_hosts_folders" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "volumes.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "volumes_on_the_platform_need_a_name" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "anonymous-volume.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "volumes_on_the_platform_cant_be_read_only" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "read-only-volume.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "deploy_makes_the_volumes_on_the_platform" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "external-volume.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "volumes_need_a_platform_that_keeps_them" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid-no-volumes.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "named-volumes.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "platform_apps_need_an_image" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "build.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "platforms_cant_fill_in_compose_variables" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "variables.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "platform_service_names_follow_the_platform" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { db = { host = "northflank-main", compose = "api.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "free_platforms_count_cloudflared_too" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = "tests/fixtures/platform/cloudflare.tfstate"
    apps = {
      api    = { host = "northflank-main", compose = "api.yaml" }
      worker = { host = "northflank-main", compose = "list-env.yaml" }
    }
  }

  expect_failures = [output.platforms]
}

run "routes_must_reach_an_app_on_the_platform" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = "tests/fixtures/platform/cloudflare.tfstate"
    apps                 = { worker = { host = "northflank-main", compose = "list-env.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "routes_must_reach_a_port_the_app_listens_on" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = "tests/fixtures/platform/cloudflare.tfstate"
    apps                 = { api = { host = "northflank-main", compose = "../compose.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "hosts_and_platforms_side_by_side" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = "tests/fixtures/platform/cloudflare.tfstate"
    apps = {
      api = { host = "northflank-main", compose = "api.yaml" }
      web = { host = "oci-main", compose = "../compose.yaml" }
    }
  }

  assert {
    condition = (
      output.targets["oci-main"].kind == "host" && output.targets["oci-main"].address == "203.0.113.10" &&
      keys(output.platforms) == ["northflank-main"] && keys(output.platforms["northflank-main"].services) == ["api"]
    )
    error_message = "Hosts keep their SSH plan, and only platform targets get services."
  }
}

run "a_bucket_puts_its_s3_settings_in_the_apps_environment" {
  command = plan

  variables {
    storage_state_paths = ["tests/fixtures/storage.tfstate"]
    apps = {
      api = { host = "oci-main", compose = "compose.yaml", bucket = "backblaze-b2-results" }
      web = { host = "oci-main", compose = "compose.yaml" }
    }
  }

  assert {
    condition = nonsensitive(output.app_env) == {
      api = {
        AWS_ACCESS_KEY_ID     = "mock-key-id"
        AWS_SECRET_ACCESS_KEY = "mock-key"
        AWS_REGION            = "us-west-004"
        AWS_ENDPOINT_URL_S3   = "https://s3.us-west-004.backblazeb2.com"
        S3_BUCKET             = "freelunch-results"
      }
    }
    error_message = "An app with a bucket gets its endpoint, region, name and keys; one without gets nothing."
  }

  assert {
    condition     = output.targets["oci-main"].apps.api.bucket == "backblaze-b2-results" && output.targets["oci-main"].apps.web.bucket == null
    error_message = "The deploy plan says which app has a bucket."
  }
}

run "apps_need_a_bucket_a_stack_made" {
  command = plan

  variables {
    storage_state_paths = ["tests/fixtures/storage.tfstate"]
    apps                = { api = { host = "oci-main", compose = "compose.yaml", bucket = "cloudflare-results" } }
  }

  expect_failures = [output.targets]
}
