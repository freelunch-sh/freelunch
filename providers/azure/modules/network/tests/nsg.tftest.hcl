# Runs offline: `terraform test` / `tofu test` from providers/azure/modules/network.

mock_provider "azurerm" {}

variables {
  resource_group_name = "freelunch-rg"
  location            = "eastus"
}

run "ports_and_cidrs_become_rules" {
  command = plan

  variables {
    ssh_source_cidrs  = ["203.0.113.7/32"]
    ingress_tcp_ports = [80, 443, 8080]
    ingress_udp_ports = [51820]
  }

  assert {
    condition     = output.ingress.ssh_source_cidrs == tolist(["203.0.113.7/32"]) && output.ingress.tcp_ports == tolist(["443", "80", "8080"]) && output.ingress.udp_ports == tolist(["51820"])
    error_message = "Every SSH source and ingress port should reach the NSG."
  }
}

run "empty_lists_create_no_rules" {
  command = plan

  variables {
    ssh_source_cidrs  = []
    ingress_tcp_ports = []
    ingress_udp_ports = []
  }

  assert {
    condition     = output.ingress.ssh_source_cidrs == null && output.ingress.tcp_ports == null && output.ingress.udp_ports == null
    error_message = "Empty lists should create no allow rules."
  }

  assert {
    condition     = [for r in azurerm_network_security_group.this.security_rule : r.name] == ["icmp"]
    error_message = "Only the ICMP rule should remain."
  }
}
