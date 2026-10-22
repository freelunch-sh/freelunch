# Runs offline: `terraform test` / `tofu test` from providers/oci/modules/docker-host.

mock_provider "oci" {
  mock_data "oci_identity_region_subscriptions" {
    defaults = {
      region_subscriptions = [
        { region_name = "eu-frankfurt-1", region_key = "FRA", is_home_region = true, state = "READY", tenancy_id = "ocid1.tenancy.oc1..mock" },
      ]
    }
  }

  mock_data "oci_identity_availability_domains" {
    defaults = {
      availability_domains = [{ name = "Xyz:EU-FRANKFURT-1-AD-1", id = "ad1", compartment_id = "ocid1.tenancy.oc1..mock" }]
    }
  }

  mock_data "oci_core_shapes" {
    defaults = {
      shapes = [{ name = "VM.Standard.A1.Flex" }, { name = "VM.Standard.E2.1.Micro" }]
    }
  }

  mock_data "oci_core_images" {
    defaults = {
      images = [{ id = "ocid1.image.oc1..mock" }]
    }
  }
}

variables {
  tenancy_id        = "ocid1.tenancy.oc1..mock"
  region            = "eu-frankfurt-1"
  ssh_public_keys   = ["ssh-ed25519 AAAAmock test"]
  ingress_tcp_ports = [80, 443, 8080]
  ingress_udp_ports = [51820]
}

run "ingress_ports_are_opened_in_host_firewall" {
  command = plan

  assert {
    condition = alltrue([
      for p in ["80", "443", "8080"] :
      strcontains(module.bootstrap["main"].user_data, "-m tcp --dport ${p} -j ACCEPT")
    ])
    error_message = "Every TCP ingress port should be opened in the host firewall."
  }

  assert {
    condition     = strcontains(module.bootstrap["main"].user_data, "-p udp -m udp --dport 51820 -j ACCEPT")
    error_message = "UDP ingress ports should be opened in the host firewall."
  }

  assert {
    condition     = !strcontains(module.bootstrap["main"].user_data, "netfilter-persistent save")
    error_message = "Saving with netfilter-persistent would capture Docker's chains."
  }

  assert {
    condition     = can(yamldecode(module.bootstrap["main"].user_data))
    error_message = "Rendered cloud-init must stay valid YAML with the firewall commands."
  }
}
