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

# Hooks -----------------------------------------------------------------------------------

run "hooks_and_service_reach_the_target" {
  command = plan

  variables {
    apps = { api = { host = "oci-main", compose = "compose.yaml", pre_deploy = "bin/migrate", post_deploy = "bin/warm", service = "web" } }
  }

  assert {
    condition = (
      output.targets["oci-main"].apps.api.pre_deploy == "bin/migrate" &&
      output.targets["oci-main"].apps.api.post_deploy == "bin/warm" &&
      output.targets["oci-main"].apps.api.service == "web"
    )
    error_message = "Hooks and the service they run in are part of the app's target."
  }
}

run "a_hook_is_one_line" {
  command = plan

  variables {
    apps = { api = { host = "oci-main", compose = "compose.yaml", pre_deploy = "a\nb" } }
  }

  expect_failures = [var.apps]
}

run "a_service_is_a_service_name" {
  command = plan

  variables {
    apps = { api = { host = "oci-main", compose = "compose.yaml", service = "web; rm -rf /" } }
  }

  expect_failures = [var.apps]
}

run "hooks_are_an_error_on_a_platform" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "api.yaml", pre_deploy = "bin/migrate" } }
  }

  expect_failures = [output.platforms]
}

# Shared hosts ----------------------------------------------------------------------------

run "a_shared_host_carries_its_project_and_arch" {
  command = plan

  variables {
    project = "shop"
    hosts   = { oci-big = { address = "203.0.113.50", shared = true, arch = "arm64" } }
    apps    = { api = { host = "oci-big", compose = "compose-limited.yaml" } }
  }

  assert {
    condition = (
      output.targets["oci-big"].shared &&
      output.targets["oci-big"].project == "shop" &&
      output.targets["oci-big"].arch == "arm64" &&
      output.targets["oci-big"].address == "203.0.113.50"
    )
    error_message = "A shared host has the project's name, and the arch the override gives when the inventory has none."
  }

  assert {
    condition     = !output.targets["oci-main"].shared && output.targets["oci-main"].project == null
    error_message = "A host of this project's own is not shared."
  }
}

run "apps_on_a_shared_host_reserve_their_memory_limits" {
  command = plan

  variables {
    project = "shop"
    hosts   = { oci-big = { address = "203.0.113.50", shared = true, arch = "arm64" } }
    apps    = { api = { host = "oci-big", compose = "compose-limited.yaml" } }
  }

  assert {
    condition     = output.targets["oci-big"].apps.api.memory_mb == 1536
    error_message = "An app reserves the sum of its services' limits: 512M in deploy.resources.limits.memory and 1g in mem_limit are 1536 MB."
  }
}

run "apps_on_a_shared_host_need_memory_limits" {
  command = plan

  variables {
    project = "shop"
    hosts   = { oci-big = { address = "203.0.113.50", shared = true, arch = "arm64" } }
    apps    = { api = { host = "oci-big", compose = "compose.yaml" } }
  }

  expect_failures = [output.targets]
}

run "apps_on_a_host_of_their_own_need_no_limit" {
  command = plan

  assert {
    condition     = output.targets["oci-main"].apps.api.memory_mb == null
    error_message = "Only a shared host asks for limits."
  }
}

run "a_shared_host_needs_an_address_an_arch_and_a_project" {
  command = plan

  variables {
    hosts = { oci-big = { shared = true } }
    apps  = { api = { host = "oci-big", compose = "compose.yaml" } }
  }

  expect_failures = [output.targets]
}

run "a_project_name_has_no_double_hyphen" {
  command = plan

  variables {
    project = "my--shop"
  }

  expect_failures = [var.project]
}

# Backups ---------------------------------------------------------------------------------

run "a_backup_reaches_the_target_with_its_buckets_settings" {
  command = plan

  variables {
    storage_state_paths = ["tests/fixtures/storage.tfstate"]
    apps = {
      api = {
        host    = "oci-main"
        compose = "compose-data.yaml"
        backup  = { bucket = "backblaze-b2-results", schedule = "daily 02:00", before = "bin/dump", keep_daily = 3 }
      }
    }
  }

  assert {
    condition = (
      output.targets["oci-main"].apps.api.backup.schedule == "daily 02:00" &&
      output.targets["oci-main"].apps.api.backup.bucket == "backblaze-b2-results" &&
      output.targets["oci-main"].apps.api.backup.before == "bin/dump" &&
      output.targets["oci-main"].apps.api.backup.keep_daily == 3 &&
      output.targets["oci-main"].apps.api.backup.keep_weekly == 4 &&
      length(output.targets["oci-main"].apps.api.backup.paths) == 0
    )
    error_message = "A backup keeps its bucket, schedule, hook and retention, with defaults of 7 daily and 4 weekly."
  }

  assert {
    condition     = nonsensitive(output.backup_env["api"].bucket) == "freelunch-results" && nonsensitive(output.backup_env["api"].endpoint) == "https://s3.us-west-004.backblazeb2.com"
    error_message = "The bucket's S3 settings are handed to deploy for the app, apart from its environment."
  }
}

run "a_backup_goes_to_a_bucket_somebody_made" {
  command = plan

  variables {
    apps = { api = { host = "oci-main", compose = "compose-data.yaml", backup = { bucket = "backblaze-b2-nothing", schedule = "daily 02:00" } } }
  }

  expect_failures = [output.targets]
}

run "a_backup_needs_a_volume_or_paths" {
  command = plan

  variables {
    storage_state_paths = ["tests/fixtures/storage.tfstate"]
    apps                = { api = { host = "oci-main", compose = "compose.yaml", backup = { bucket = "backblaze-b2-results", schedule = "daily 02:00" } } }
  }

  expect_failures = [output.targets]
}

run "paths_are_something_to_back_up" {
  command = plan

  variables {
    storage_state_paths = ["tests/fixtures/storage.tfstate"]
    apps                = { api = { host = "oci-main", compose = "compose.yaml", backup = { bucket = "backblaze-b2-results", schedule = "daily 02:00", paths = ["/srv/uploads"] } } }
  }

  assert {
    condition     = output.targets["oci-main"].apps.api.backup.paths == tolist(["/srv/uploads"])
    error_message = "A backup of paths on the host needs no volume."
  }
}

run "a_backup_schedule_has_one_of_three_forms" {
  command = plan

  variables {
    storage_state_paths = ["tests/fixtures/storage.tfstate"]
    apps                = { api = { host = "oci-main", compose = "compose-data.yaml", backup = { bucket = "backblaze-b2-results", schedule = "nightly" } } }
  }

  expect_failures = [var.apps]
}

run "backup_paths_are_absolute" {
  command = plan

  variables {
    storage_state_paths = ["tests/fixtures/storage.tfstate"]
    apps                = { api = { host = "oci-main", compose = "compose-data.yaml", backup = { bucket = "backblaze-b2-results", schedule = "daily 02:00", paths = ["uploads"] } } }
  }

  expect_failures = [var.apps]
}

run "backups_are_an_error_on_a_platform" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    storage_state_paths  = ["tests/fixtures/storage.tfstate"]
    apps                 = { api = { host = "northflank-main", compose = "api.yaml", backup = { bucket = "backblaze-b2-results", schedule = "daily 02:00", paths = ["/x"] } } }
  }

  expect_failures = [output.platforms]
}

# Jobs ------------------------------------------------------------------------------------

run "jobs_reach_the_host_their_app_runs_on" {
  command = plan

  variables {
    jobs = {
      nightly = { app = "api", command = "bin/report", schedule = "daily 03:30", heavy = true, timeout_minutes = 30 }
      ping    = { app = "api", command = "bin/ping", schedule = "hourly :15", service = "web" }
    }
  }

  assert {
    condition = (
      output.targets["oci-main"].jobs.nightly.schedule == "daily 03:30" &&
      output.targets["oci-main"].jobs.nightly.heavy &&
      output.targets["oci-main"].jobs.nightly.timeout_minutes == 30 &&
      !output.targets["oci-main"].jobs.ping.heavy &&
      output.targets["oci-main"].jobs.ping.timeout_minutes == 60 &&
      output.targets["oci-main"].jobs.ping.service == "web"
    )
    error_message = "A job is part of its app's host, with defaults for heavy and the timeout."
  }
}

run "a_job_needs_an_app_that_exists" {
  command = plan

  variables {
    jobs = { nightly = { app = "nothing", command = "bin/report", schedule = "daily 03:30" } }
  }

  expect_failures = [output.targets]
}

run "a_schedule_has_one_of_three_forms" {
  command = plan

  variables {
    jobs = { nightly = { app = "api", command = "bin/report", schedule = "every day at 3" } }
  }

  expect_failures = [var.jobs]
}

run "a_weekly_schedule_names_a_day" {
  command = plan

  variables {
    jobs = { nightly = { app = "api", command = "bin/report", schedule = "weekly someday 03:00" } }
  }

  expect_failures = [var.jobs]
}

run "a_job_name_is_a_unit_name" {
  command = plan

  variables {
    jobs = { "Night Report" = { app = "api", command = "bin/report", schedule = "daily 03:30" } }
  }

  expect_failures = [var.jobs]
}

run "jobs_are_an_error_on_a_platform" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "api.yaml" } }
    jobs                 = { nightly = { app = "api", command = "bin/report", schedule = "daily 03:30" } }
  }

  expect_failures = [output.platforms]
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
      plan        = "nf-compute-20"
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
      plan        = "nf-compute-20"
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
    condition     = output.platforms["northflank-main"].volume_size == 6144
    error_message = "The volume size comes from the platform stack."
  }

  assert {
    condition     = abs(output.platforms["northflank-main"].cost - (5.4 + 12 * 0.11657)) < 0.001 && output.platforms["northflank-main"].budget == 20
    error_message = "The app's service and two 6 GB volumes cost about $6.80 a month, of the $20 the free plan covers."
  }
}

run "volumes_have_to_fit_in_the_free_plan" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid-big-volumes.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "named-volumes.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "platforms_without_prices_have_no_estimate" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid-no-volumes.tfstate"
    tunnel_state_path    = null
    apps                 = { api = { host = "northflank-main", compose = "api.yaml" } }
  }

  assert {
    condition     = output.platforms["northflank-main"].cost == null && output.platforms["northflank-main"].budget == null
    error_message = "A platform stack that gives no prices gets no estimate and no check."
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

run "an_app_without_a_host_goes_to_the_default_host" {
  command = plan

  variables {
    default_host = "oci-main"
    apps         = { api = { compose = "compose.yaml", env_file = "api.env" } }
  }

  assert {
    condition     = keys(output.targets) == ["oci-main"] && keys(output.targets["oci-main"].apps) == ["api"]
    error_message = "An app that names no host runs on default_host."
  }
}

run "a_named_host_beats_the_default_host" {
  command = plan

  variables {
    default_host = "oci-other"
    apps         = { api = { host = "oci-main", compose = "compose.yaml" } }
  }

  assert {
    condition     = keys(output.targets) == ["oci-main"]
    error_message = "default_host only fills in for apps that name no host."
  }
}

run "an_app_without_a_host_and_no_default_fails" {
  command = plan

  variables {
    apps = { api = { compose = "compose.yaml" } }
  }

  expect_failures = [output.targets]
}

run "an_app_may_have_a_plan_of_its_own" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = "tests/fixtures/platform/cloudflare.tfstate"
    apps                 = { api = { host = "northflank-main", compose = "api.yaml", env_file = "../api.env", plan = "nf-compute-10" } }
  }

  assert {
    condition     = output.platforms["northflank-main"].services.api.plan == "nf-compute-10"
    error_message = "The app's plan beats the stack's."
  }
}

run "a_plan_outside_the_free_plan_is_refused" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    tunnel_state_path    = "tests/fixtures/platform/cloudflare.tfstate"
    apps                 = { api = { host = "northflank-main", compose = "api.yaml", env_file = "../api.env", plan = "nf-compute-50" } }
  }

  expect_failures = [output.platforms]
}

run "a_memory_limit_picks_the_smallest_plan_that_holds_it" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    apps                 = { small = { host = "northflank-main", compose = "mem-small.yaml" } }
  }

  assert {
    condition     = output.platforms["northflank-main"].services.small.plan == "nf-compute-10"
    error_message = "200M fits nf-compute-10 (256 MB)."
  }
}

run "a_memory_limit_may_need_the_bigger_free_plan" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    apps                 = { mid = { host = "northflank-main", compose = "mem-mid.yaml" } }
  }

  assert {
    condition     = output.platforms["northflank-main"].services.mid.plan == "nf-compute-20"
    error_message = "300M needs nf-compute-20."
  }
}

run "a_memory_limit_no_plan_holds_is_refused" {
  command = plan

  variables {
    config_dir           = "tests/fixtures/platform"
    inventory_state_path = "tests/fixtures/platform/hybrid.tfstate"
    apps                 = { big = { host = "northflank-main", compose = "mem-big.yaml" } }
  }

  expect_failures = [output.platforms]
}

run "a_database_puts_its_url_in_the_apps_environment" {
  command = plan

  variables {
    database_state_paths = ["tests/fixtures/database.tfstate"]
    storage_state_paths  = ["tests/fixtures/storage.tfstate"]
    apps = {
      api  = { host = "oci-main", compose = "compose.yaml", database = "neon-main" }
      web  = { host = "oci-main", compose = "compose.yaml" }
      both = { host = "oci-main", compose = "compose.yaml", database = "neon-main", bucket = "backblaze-b2-results" }
    }
  }

  assert {
    condition = nonsensitive(output.app_env.api) == {
      DATABASE_URL = "postgres://owner:mock-db-pass@ep-mock.eu-central-1.aws.neon.tech/neondb?sslmode=require"
    } && !contains(keys(output.app_env), "web")
    error_message = "An app with a database gets DATABASE_URL; one without gets nothing."
  }

  assert {
    condition     = nonsensitive(output.app_env.both.DATABASE_URL) == "postgres://owner:mock-db-pass@ep-mock.eu-central-1.aws.neon.tech/neondb?sslmode=require" && nonsensitive(output.app_env.both.S3_BUCKET) == "freelunch-results"
    error_message = "An app can have a bucket and a database."
  }

  assert {
    condition     = output.targets["oci-main"].apps.api.database == "neon-main" && output.targets["oci-main"].apps.web.database == null
    error_message = "The deploy plan says which app has a database."
  }
}

run "a_database_can_come_from_an_engine_record" {
  command = plan

  variables {
    extra_databases = [{ provider = "turso", name = "app", engine = "libsql" }]
    extra_database_credentials = {
      "turso-app" = { url = "libsql://app-me.turso.io?authToken=mock-token" }
    }
    apps = {
      api = { host = "oci-main", compose = "compose.yaml", database = "turso-app" }
    }
  }

  assert {
    condition     = nonsensitive(output.app_env.api.DATABASE_URL) == "libsql://app-me.turso.io?authToken=mock-token"
    error_message = "A database an engine's record holds reaches the app the same way a stack's does."
  }
}

run "apps_need_a_database_a_stack_made" {
  command = plan

  variables {
    database_state_paths = ["tests/fixtures/database.tfstate"]
    apps                 = { api = { host = "oci-main", compose = "compose.yaml", database = "supabase-app" } }
  }

  expect_failures = [output.targets]
}

run "needs_name_other_nodes_and_feed_the_environment" {
  command = plan

  variables {
    database_state_paths = ["tests/fixtures/database.tfstate"]
    storage_state_paths  = ["tests/fixtures/storage.tfstate"]
    apps = {
      web = { host = "oci-main", compose = "compose.yaml", needs = ["api", "neon-main", "backblaze-b2-results"] }
      api = { host = "oci-main", compose = "compose.yaml", port = 8080, database = "neon-main" }
    }
  }

  assert {
    condition     = output.graph.web.host == "oci-main" && output.graph.web.port == null && join(",", output.graph.web.needs) == "api,neon-main,backblaze-b2-results" && output.graph.api.port == 8080 && join(",", output.graph.api.needs) == "neon-main"
    error_message = "The graph lists each app's host, port and effective needs; bucket and database count as needs."
  }

  assert {
    condition     = nonsensitive(output.app_env.web.NEON_MAIN_URL) == "postgres://owner:mock-db-pass@ep-mock.eu-central-1.aws.neon.tech/neondb?sslmode=require" && nonsensitive(output.app_env.web.BACKBLAZE_B2_RESULTS_BUCKET) == "freelunch-results" && !contains(keys(output.app_env.web), "DATABASE_URL")
    error_message = "A need gives the dependant the node's settings under the node's own name, and the old names stay for the old fields."
  }

  assert {
    condition     = nonsensitive(output.app_env.api) == { DATABASE_URL = "postgres://owner:mock-db-pass@ep-mock.eu-central-1.aws.neon.tech/neondb?sslmode=require" }
    error_message = "The database field still gives DATABASE_URL and nothing else."
  }
}

run "a_need_on_nothing_is_refused" {
  command = plan

  variables {
    apps = { web = { host = "oci-main", compose = "compose.yaml", needs = ["nonesuch"] } }
  }

  expect_failures = [output.graph]
}

run "a_mesh_address_is_used_for_ssh_when_asked" {
  command = plan

  variables {
    mesh = { "oci-main" = { address = "100.64.0.7", ssh = true } }
  }

  assert {
    condition     = output.targets["oci-main"].address == "100.64.0.7"
    error_message = "A host on a mesh with ssh on is reached at its mesh address."
  }
}

run "a_mesh_address_is_not_used_for_ssh_by_default" {
  command = plan

  variables {
    mesh = { "oci-main" = { address = "100.64.0.7" } }
  }

  assert {
    condition     = output.targets["oci-main"].address == "203.0.113.10"
    error_message = "Without ssh = true, the public address stays."
  }
}

run "an_address_in_apps_tfvars_beats_the_mesh" {
  command = plan

  variables {
    mesh  = { "oci-main" = { address = "100.64.0.7", ssh = true } }
    hosts = { "oci-main" = { address = "freelunch-oci-main" } }
  }

  assert {
    condition     = output.targets["oci-main"].address == "freelunch-oci-main"
    error_message = "A hand-written address wins."
  }
}

run "a_need_on_a_service_gives_the_variables_it_names" {
  command = plan

  variables {
    service_state_paths = ["tests/fixtures/service.tfstate"]
    apps = {
      api = { host = "oci-main", compose = "compose.yaml", needs = ["axiom-logs"] }
      web = { host = "oci-main", compose = "compose.yaml" }
    }
  }

  assert {
    condition     = nonsensitive(output.app_env.api) == { AXIOM_TOKEN = "xaat-mock-service-token", AXIOM_DATASET = "shop-logs" } && !contains(keys(output.app_env), "web")
    error_message = "A service gives the app the variables it names, as they are, and an app that doesn't need it gets nothing."
  }

  assert {
    condition     = join(",", output.graph.api.needs) == "axiom-logs"
    error_message = "A service is a node an app can need."
  }
}

run "a_need_on_a_service_nobody_made_is_refused" {
  command = plan

  variables {
    apps = { api = { host = "oci-main", compose = "compose.yaml", needs = ["axiom-logs"] } }
  }

  expect_failures = [output.graph]
}

run "services_and_buckets_can_come_from_engine_records" {
  command = plan

  variables {
    extra_services = [{ provider = "uptimerobot", name = "heartbeat", kind = "observability", host = "heartbeat.uptimerobot.com", port = 443 }]
    extra_service_credentials = {
      "uptimerobot-heartbeat" = { env = { HEARTBEAT_URL = "https://heartbeat.uptimerobot.com/m-mock-key" } }
    }
    extra_buckets = [{ provider = "filebase", name = "assets", bucket = "freelunch-assets", endpoint = "https://s3.filebase.com", region = "us-east-1" }]
    extra_bucket_keys = {
      "filebase-assets" = { access_key_id = "FBKEY", secret_access_key = "mock-secret" }
    }
    apps = {
      api = { host = "oci-main", compose = "compose.yaml", needs = ["uptimerobot-heartbeat"], bucket = "filebase-assets" }
    }
  }

  assert {
    condition     = nonsensitive(output.app_env.api.HEARTBEAT_URL) == "https://heartbeat.uptimerobot.com/m-mock-key"
    error_message = "A service from a record gives the app the variables it names."
  }

  assert {
    condition     = nonsensitive(output.app_env.api.S3_BUCKET) == "freelunch-assets" && nonsensitive(output.app_env.api.AWS_ACCESS_KEY_ID) == "FBKEY" && nonsensitive(output.app_env.api.AWS_ENDPOINT_URL_S3) == "https://s3.filebase.com"
    error_message = "A bucket from a record gives the app its S3 settings."
  }
}
