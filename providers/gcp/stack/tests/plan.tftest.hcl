# Runs offline: `terraform test` / `tofu test` from providers/gcp/stack.
# Plans the whole stack (API + network + bootstrap + compute) against a mocked Google API.

mock_provider "google" {}

variables {
  project_id                     = "mock-project"
  ssh_public_keys                = ["ssh-ed25519 AAAAmock test"]
  acknowledge_public_ipv4_charge = true
}

run "default_stack_plans" {
  command = plan

  assert {
    condition     = output.free_tier_usage.e2_micro_instances == "1/1" && output.free_tier_usage.standard_disk_gb == "30/30"
    error_message = "Default layout should be one e2-micro with a 30 GB standard disk."
  }

  assert {
    condition     = length(output.hosts) == 1 && output.hosts[0].provider == "gcp" && output.hosts[0].arch == "amd64" && output.hosts[0].region == "us-central1"
    error_message = "hosts output must follow the freelunch host contract."
  }

  assert {
    condition     = keys(output.hosts[0]) == ["arch", "id", "name", "private_ip", "provider", "public_ip", "region", "size", "ssh_user"]
    error_message = "hosts must carry exactly the host contract attributes."
  }
}
