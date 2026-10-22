# Runs offline: `terraform test` / `tofu test` from providers/oci/stack.
# Plans the whole stack (network + bootstrap + compute) against a mocked OCI API.

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
  region          = "eu-frankfurt-1"
  tenancy_ocid    = "ocid1.tenancy.oc1..mock"
  ssh_public_keys = ["ssh-ed25519 AAAAmock test"]
}

run "default_stack_plans" {
  command = plan

  assert {
    condition     = output.free_tier_usage.a1_ocpus == "2/2" && output.free_tier_usage.block_storage_gb == "100/200"
    error_message = "Default layout should be one 2/12 A1 host with a 100 GB boot volume."
  }

  assert {
    condition     = length(output.hosts) == 1 && output.hosts[0].provider == "oci" && output.hosts[0].arch == "arm64"
    error_message = "hosts output must follow the freelunch host contract."
  }
}

run "mixed_layout_reports_arch_per_host" {
  command = plan

  variables {
    instances = {
      main   = { boot_volume_gb = 100 }
      edge-1 = { shape = "VM.Standard.E2.1.Micro", swap_size_gb = 2 }
    }
  }

  assert {
    condition     = { for h in output.hosts : h.name => h.arch } == { main = "arm64", edge-1 = "amd64" }
    error_message = "A1 hosts are arm64 and micro hosts are amd64."
  }
}
