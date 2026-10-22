# Runs offline: `terraform test` / `tofu test` from providers/azure/modules/compute.

mock_provider "azurerm" {}

variables {
  resource_group_name = "freelunch-rg"
  location            = "eastus"
  subnet_id           = "/subscriptions/mock/resourceGroups/freelunch-rg/providers/Microsoft.Network/virtualNetworks/freelunch-vnet/subnets/freelunch-public"
  # A real (throwaway) key: azurerm parses keys even against a mocked API.
  ssh_public_keys                = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJO3Z82uTJC+igz6mw890JMFTzRdvYo1S7OFo9C+xHK2 freelunch-test"]
  acknowledge_public_ipv4_charge = true
}

run "max_free_layout_passes" {
  command = plan

  variables {
    instances = {
      amd = { size = "Standard_B2ats_v2" }
      arm = { size = "Standard_B2pts_v2" }
    }
  }

  assert {
    condition     = output.free_tier_usage.p6_disks == "2/2" && output.free_tier_usage.vms_by_size["Standard_B2pts_v2"] == "1/1"
    error_message = "Two VMs of different free sizes should use both free P6 disks."
  }

  assert {
    condition     = { for h in output.hosts : h.name => h.arch } == { amd = "amd64", arm = "arm64" }
    error_message = "B2ats v2 is amd64 and B2pts v2 is arm64."
  }

  assert {
    condition     = one(azurerm_linux_virtual_machine.this["arm"].source_image_reference).sku == "server-arm64" && one(azurerm_linux_virtual_machine.this["amd"].source_image_reference).sku == "server"
    error_message = "Each VM should boot the Ubuntu image for its architecture."
  }

  assert {
    condition = (
      one(azurerm_linux_virtual_machine.this["amd"].os_disk).storage_account_type == "Premium_LRS" &&
      one(azurerm_linux_virtual_machine.this["amd"].os_disk).disk_size_gb == 64 &&
      azurerm_linux_virtual_machine.this["amd"].disable_password_authentication
    )
    error_message = "Defaults should be a 64 GB Premium SSD (P6) and key-only SSH."
  }

  assert {
    condition     = azurerm_public_ip.this["amd"].sku == "Standard" && azurerm_public_ip.this["amd"].allocation_method == "Static"
    error_message = "Public IPs should be Standard static (Basic SKU is retired)."
  }
}

run "public_ipv4_needs_acknowledgement" {
  command = plan

  variables {
    instances                      = { main = {} }
    acknowledge_public_ipv4_charge = false
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "private_only_vm_needs_no_acknowledgement" {
  command = plan

  variables {
    instances                      = { main = { assign_public_ip = false } }
    acknowledge_public_ipv4_charge = false
  }

  assert {
    condition     = length(azurerm_public_ip.this) == 0 && output.free_tier_usage.billed_public_ipv4s == 0
    error_message = "assign_public_ip = false should create no public IP."
  }
}

run "two_vms_of_one_size_are_blocked" {
  command = plan

  variables {
    instances = {
      a = { size = "Standard_B2ats_v2" }
      b = { size = "Standard_B2ats_v2" }
    }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "third_vm_is_blocked" {
  command = plan

  variables {
    instances = {
      a = { size = "Standard_B2ats_v2" }
      b = { size = "Standard_B2pts_v2" }
      c = { size = "Standard_B1s" }
    }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "non_free_size_is_blocked" {
  command = plan

  variables {
    instances = { main = { size = "Standard_B2s" } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "p4_sized_disk_is_blocked" {
  command = plan

  variables {
    instances = { main = { os_disk_gb = 30 } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "standard_ssd_is_blocked" {
  command = plan

  variables {
    instances = { main = { os_disk_type = "StandardSSD_LRS" } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "acknowledged_billing_allows_other_sizes" {
  command = plan

  variables {
    instances                      = { main = { size = "Standard_D2ps_v5", os_disk_gb = 128 } }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = output.hosts[0].arch == "arm64" && output.free_tier_usage.p6_disks == "0/2"
    error_message = "D2ps v5 is Arm, and a 128 GB disk is not P6."
  }
}
