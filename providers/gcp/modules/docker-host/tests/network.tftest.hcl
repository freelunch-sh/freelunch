# Runs offline: `terraform test` / `tofu test` from providers/gcp/modules/docker-host.

mock_provider "google" {}

variables {
  region                         = "us-central1"
  ssh_public_keys                = ["ssh-ed25519 AAAAmock test"]
  acknowledge_public_ipv4_charge = true
}

run "ports_become_firewall_rules" {
  command = plan

  variables {
    ingress_tcp_ports = [80, 443, 8080]
    ingress_udp_ports = [51820]
  }

  assert {
    condition     = module.network.ingress.tcp_ports == tolist(["80", "443", "8080"]) && module.network.ingress.udp_ports == tolist(["51820"])
    error_message = "Every ingress port should be allowed by a firewall rule."
  }

  assert {
    condition     = can(yamldecode(module.bootstrap["main"].user_data)) && yamldecode(module.bootstrap["main"].user_data).swap.size == 2147483648
    error_message = "Hosts should boot valid cloud-init with 2 GB of swap by default."
  }
}

run "empty_port_lists_create_no_allow_all_rules" {
  command = plan

  variables {
    ssh_source_cidrs  = []
    ingress_tcp_ports = []
    ingress_udp_ports = []
  }

  # An allow block without ports opens every port, so the rules must not exist at all.
  assert {
    condition     = module.network.ingress.tcp_ports == null && module.network.ingress.udp_ports == null && module.network.ingress.ssh_source_cidrs == null
    error_message = "Empty port or CIDR lists must not create firewall rules."
  }
}
