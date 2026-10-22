# Runs offline: `terraform test` / `tofu test` from hybrid/. Uses fixture state files.

variables {
  host_providers = ["oci", "gcp", "aws", "azure"]
  state_overrides = {
    oci   = { backend = "local", config = { path = "tests/fixtures/oci.tfstate" } }
    gcp   = { backend = "local", config = { path = "tests/fixtures/gcp.tfstate" } }
    aws   = { backend = "local", config = { path = "tests/fixtures/aws.tfstate" } }
    azure = { backend = "local", config = { path = "tests/fixtures/azure.tfstate" } }
  }
}

run "aggregates_hosts_across_providers" {
  command = plan

  assert {
    condition     = length(output.hosts) == 5
    error_message = "Expected 2 OCI hosts + 1 GCP + 1 AWS + 1 Azure host."
  }

  assert {
    condition = (
      output.hosts_by_provider.oci == { main = "203.0.113.10", edge-1 = "203.0.113.11" } &&
      output.hosts_by_provider.gcp == { micro = "198.51.100.20" } &&
      output.hosts_by_provider.aws == { main = "192.0.2.30" } &&
      output.hosts_by_provider.azure.arm == null
    )
    error_message = "hosts_by_provider should map provider -> host name -> public IP (null when private-only)."
  }

  assert {
    condition     = keys(yamldecode(output.ansible_inventory).all.children) == ["amd64", "arm64", "aws", "azure", "gcp", "oci"]
    error_message = "Inventory needs one group per provider and per architecture."
  }

  assert {
    condition     = strcontains(output.ssh_config, "Host gcp-micro\n  HostName 198.51.100.20\n  User ubuntu")
    error_message = "ssh_config should contain a Host block per host."
  }

  assert {
    condition     = keys(yamldecode(output.ansible_inventory).all.children.arm64.hosts) == ["azure-arm", "oci-main"]
    error_message = "Arm hosts from every provider should share the arm64 group."
  }
}

run "private_only_hosts_fall_back_to_the_private_ip" {
  command = plan

  assert {
    condition     = strcontains(output.ssh_config, "Host azure-arm\n  HostName 10.0.1.4\n  User azureuser")
    error_message = "A host without a public IP should be reachable by its private IP (over Tailscale or a VPN)."
  }

  assert {
    condition     = yamldecode(output.ansible_inventory).all.children.azure.hosts["azure-arm"].ansible_host == "10.0.1.4"
    error_message = "Ansible should target the private IP when there is no public one."
  }
}

run "no_providers_yields_empty_inventory" {
  command = plan

  variables {
    host_providers  = []
    state_overrides = {}
  }

  assert {
    condition     = length(output.hosts) == 0
    error_message = "No providers means no hosts."
  }
}

run "project_state_dir_is_read" {
  command = plan

  variables {
    host_providers  = ["oci", "gcp"]
    state_dir       = "tests/fixtures/project"
    state_overrides = {}
  }

  assert {
    condition     = output.hosts_by_provider == { oci = { main = "203.0.113.10", edge-1 = "203.0.113.11" }, gcp = { micro = "198.51.100.20" } }
    error_message = "With state_dir set, each provider's state is read from <state_dir>/<provider>/terraform.tfstate."
  }
}
