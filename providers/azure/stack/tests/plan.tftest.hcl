# Runs offline: `terraform test` / `tofu test` from providers/azure/stack.
# Plans the whole stack (resource group + network + bootstrap + compute) against a mocked Azure API.

mock_provider "azurerm" {}

variables {
  location = "eastus"
  # A real (throwaway) key: azurerm parses keys even against a mocked API.
  ssh_public_keys                = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJO3Z82uTJC+igz6mw890JMFTzRdvYo1S7OFo9C+xHK2 freelunch-test"]
  acknowledge_public_ipv4_charge = true
}

run "default_stack_plans" {
  command = plan

  assert {
    condition     = output.free_tier_usage.p6_disks == "1/2" && output.free_tier_usage.vms_by_size["Standard_B2ats_v2"] == "1/1"
    error_message = "Default layout should be one B2ats v2 with a 64 GB P6 disk."
  }

  assert {
    condition     = length(output.hosts) == 1 && output.hosts[0].provider == "azure" && output.hosts[0].arch == "amd64" && output.hosts[0].region == "eastus"
    error_message = "hosts output must follow the freelunch host contract."
  }

  assert {
    condition     = keys(output.hosts[0]) == ["arch", "id", "name", "private_ip", "provider", "public_ip", "region", "size", "ssh_user"]
    error_message = "hosts must carry exactly the host contract attributes."
  }
}
