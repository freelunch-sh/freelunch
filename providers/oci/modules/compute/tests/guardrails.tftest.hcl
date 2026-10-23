# Runs offline: `terraform test` / `tofu test` from providers/oci/modules/compute.

mock_provider "oci" {
  mock_data "oci_identity_region_subscriptions" {
    defaults = {
      region_subscriptions = [
        { region_name = "eu-frankfurt-1", region_key = "FRA", is_home_region = true, state = "READY", tenancy_id = "ocid1.tenancy.oc1..mock" },
        { region_name = "eu-amsterdam-1", region_key = "AMS", is_home_region = false, state = "READY", tenancy_id = "ocid1.tenancy.oc1..mock" },
      ]
    }
  }

  mock_data "oci_identity_availability_domains" {
    defaults = {
      availability_domains = [
        { name = "Xyz:EU-FRANKFURT-1-AD-1", id = "ad1", compartment_id = "ocid1.tenancy.oc1..mock" },
        { name = "Xyz:EU-FRANKFURT-1-AD-2", id = "ad2", compartment_id = "ocid1.tenancy.oc1..mock" },
      ]
    }
  }

  mock_data "oci_core_shapes" {
    defaults = {
      shapes = [{ name = "VM.Standard.A1.Flex" }]
    }
  }

  mock_data "oci_core_images" {
    defaults = {
      images = [{ id = "ocid1.image.oc1..mock" }]
    }
  }
}

# The micro shape only exists in AD-2 in this fake region.
override_data {
  target = data.oci_core_shapes.by_ad["Xyz:EU-FRANKFURT-1-AD-2"]
  values = {
    shapes = [{ name = "VM.Standard.A1.Flex" }, { name = "VM.Standard.E2.1.Micro" }]
  }
}

variables {
  tenancy_id      = "ocid1.tenancy.oc1..mock"
  compartment_id  = "ocid1.tenancy.oc1..mock"
  region          = "eu-frankfurt-1"
  subnet_id       = "ocid1.subnet.oc1..mock"
  ssh_public_keys = ["ssh-ed25519 AAAAmock test"]
}

run "max_free_layout_passes" {
  command = plan

  variables {
    instances = {
      main   = { ocpus = 2, memory_in_gbs = 12, boot_volume_gb = 100 }
      edge-1 = { shape = "VM.Standard.E2.1.Micro", boot_volume_gb = 50 }
      edge-2 = { shape = "VM.Standard.E2.1.Micro", boot_volume_gb = 50 }
    }
  }

  assert {
    condition     = output.free_tier_usage.block_storage_gb == "200/200"
    error_message = "Expected 200 GB of the 200 GB cap to be planned."
  }

  assert {
    condition     = oci_core_instance.this["edge-1"].availability_domain == "Xyz:EU-FRANKFURT-1-AD-2"
    error_message = "Micro instance should be placed in the only AD that offers the shape."
  }

  assert {
    condition     = oci_core_instance.this["main"].availability_domain == "Xyz:EU-FRANKFURT-1-AD-1"
    error_message = "A1 instance should be placed in the first AD that offers the shape."
  }
}

# Capacity retries raise the offset by one to try the next AD that offers the shape.
run "offset_moves_to_the_next_ad_with_the_shape" {
  command = plan

  variables {
    instances = {
      main   = { ocpus = 2, memory_in_gbs = 12, boot_volume_gb = 100 }
      edge-1 = { shape = "VM.Standard.E2.1.Micro", boot_volume_gb = 50 }
      pinned = { shape = "VM.Standard.E2.1.Micro", boot_volume_gb = 50, availability_domain_index = 1 }
    }
    availability_domain_offset = 1
  }

  assert {
    condition     = oci_core_instance.this["main"].availability_domain == "Xyz:EU-FRANKFURT-1-AD-2"
    error_message = "With offset 1 the A1 instance should go to the second AD that offers its shape."
  }

  assert {
    condition     = oci_core_instance.this["edge-1"].availability_domain == "Xyz:EU-FRANKFURT-1-AD-2"
    error_message = "The micro shape is offered in one AD only, so every offset lands there."
  }

  assert {
    condition     = oci_core_instance.this["pinned"].availability_domain == "Xyz:EU-FRANKFURT-1-AD-2"
    error_message = "availability_domain_index should win over the offset."
  }
}

run "offset_wraps_around" {
  command = plan

  variables {
    instances                  = { main = {} }
    availability_domain_offset = 5
  }

  assert {
    condition     = oci_core_instance.this["main"].availability_domain == "Xyz:EU-FRANKFURT-1-AD-2"
    error_message = "Offset 5 over two ADs should land on the second one."
  }
}

run "offset_must_be_a_whole_number" {
  command = plan

  variables {
    instances                  = { main = {} }
    availability_domain_offset = 1.5
  }

  expect_failures = [var.availability_domain_offset]
}

run "legacy_4_24_a1_is_blocked" {
  command = plan

  variables {
    instances = { main = { ocpus = 4, memory_in_gbs = 24 } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "two_a1_hosts_over_cap_are_blocked" {
  command = plan

  variables {
    instances = {
      a = { ocpus = 2, memory_in_gbs = 12 }
      b = { ocpus = 1, memory_in_gbs = 6 }
    }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "third_micro_is_blocked" {
  command = plan

  variables {
    instances = {
      m1 = { shape = "VM.Standard.E2.1.Micro" }
      m2 = { shape = "VM.Standard.E2.1.Micro" }
      m3 = { shape = "VM.Standard.E2.1.Micro" }
    }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "storage_over_200gb_is_blocked" {
  command = plan

  variables {
    instances                 = { main = { boot_volume_gb = 150 } }
    reserved_block_storage_gb = 60
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "non_free_shape_is_blocked" {
  command = plan

  variables {
    instances = { main = { shape = "VM.Standard.E5.Flex", ocpus = 1, memory_in_gbs = 8 } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "non_home_region_is_blocked" {
  command = plan

  variables {
    region    = "eu-amsterdam-1"
    instances = { main = {} }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "acknowledged_billing_allows_over_cap" {
  command = plan

  variables {
    instances                      = { main = { ocpus = 4, memory_in_gbs = 24 } }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = output.free_tier_usage.a1_ocpus == "4/2"
    error_message = "Usage output should report the overage."
  }
}
