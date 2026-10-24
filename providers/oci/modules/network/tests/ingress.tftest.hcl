# Runs offline: `terraform test` / `tofu test` from providers/oci/modules/network.

mock_provider "oci" {}

variables {
  compartment_id = "ocid1.tenancy.oc1..mock"
}

run "tunnel_layout_opens_only_ssh" {
  command = plan

  variables {
    ssh_source_cidrs  = ["198.51.100.7/32"]
    ingress_tcp_ports = []
  }

  assert {
    condition = (
      [for r in oci_core_security_list.public.ingress_security_rules : r.description if r.source == "0.0.0.0/0"] ==
      ["ICMP fragmentation needed"]
    )
    error_message = "With no ingress ports (Cloudflare Tunnel), only path MTU ICMP may come from anywhere."
  }

  assert {
    condition = (
      [for r in oci_core_security_list.public.ingress_security_rules : r.source if r.protocol == "6"] ==
      ["198.51.100.7/32"]
    )
    error_message = "The only TCP rule should be SSH from ssh_source_cidrs."
  }
}

run "public_ports_are_opened" {
  command = plan

  assert {
    condition     = toset([for r in oci_core_security_list.public.ingress_security_rules : r.description if r.protocol == "6"]) == toset(["SSH", "tcp/80", "tcp/443"])
    error_message = "By default SSH, 80 and 443 are open."
  }
}

# A project that sets name_prefix after its network exists renames it in place.
run "network_before_the_rename" {
  variables {
    name = "freelunch"
  }
}

run "renaming_keeps_the_vcn" {
  command = plan

  variables {
    name = "moneyspider"
  }

  assert {
    condition     = oci_core_vcn.this.dns_label == "freelunch" && oci_core_vcn.this.display_name == "moneyspider-vcn"
    error_message = "A new name should rename the VCN, not replace it for a new DNS label."
  }
}
