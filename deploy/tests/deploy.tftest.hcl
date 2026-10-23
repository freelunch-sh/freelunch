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
