# Runs offline: `terraform test` / `tofu test` from providers/azure/modules/docker-host.

mock_provider "azurerm" {}

variables {
  location = "eastus"
  # A real (throwaway) key: azurerm parses keys even against a mocked API.
  ssh_public_keys                = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJO3Z82uTJC+igz6mw890JMFTzRdvYo1S7OFo9C+xHK2 freelunch-test"]
  acknowledge_public_ipv4_charge = true
}

run "hosts_boot_docker_as_the_admin_user" {
  command = plan

  variables {
    admin_username = "ops"
  }

  assert {
    condition     = contains(yamldecode(module.bootstrap["main"].user_data).runcmd, "usermod -aG docker ops")
    error_message = "The admin user should join the docker group."
  }

  assert {
    condition     = output.resource_group_name == "freelunch-rg" && output.hosts[0].ssh_user == "ops"
    error_message = "Everything lives in <name_prefix>-rg, and the host contract reports the admin user."
  }
}
