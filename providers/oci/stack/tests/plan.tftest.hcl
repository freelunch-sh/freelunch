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
      shapes = [
        { name = "VM.Standard.A1.Flex", baseline_ocpu_utilizations = null, billing_type = null, bs_nvme_attachments_config = null, gpu_description = null, gpus = null, is_billed_for_stopped_instance = null, is_cnic = null, is_flexible = null, is_live_migration_supported = null, is_subcore = null, local_disk_description = null, local_disks = null, local_disks_total_size_in_gbs = null, max_vnic_attachment_options = null, max_vnic_attachments = null, memory_in_gbs = null, memory_options = null, min_total_baseline_ocpus_required = null, network_ports = null, networking_bandwidth_in_gbps = null, networking_bandwidth_options = null, ocpu_options = null, ocpus = null, platform_config_options = null, platform_names = null, processor_description = null, quota_names = null, rdma_bandwidth_in_gbps = null, rdma_ports = null, recommended_alternatives = null, resize_compatible_shapes = null, supported_resource_management = null },
        { name = "VM.Standard.E2.1.Micro", baseline_ocpu_utilizations = null, billing_type = null, bs_nvme_attachments_config = null, gpu_description = null, gpus = null, is_billed_for_stopped_instance = null, is_cnic = null, is_flexible = null, is_live_migration_supported = null, is_subcore = null, local_disk_description = null, local_disks = null, local_disks_total_size_in_gbs = null, max_vnic_attachment_options = null, max_vnic_attachments = null, memory_in_gbs = null, memory_options = null, min_total_baseline_ocpus_required = null, network_ports = null, networking_bandwidth_in_gbps = null, networking_bandwidth_options = null, ocpu_options = null, ocpus = null, platform_config_options = null, platform_names = null, processor_description = null, quota_names = null, rdma_bandwidth_in_gbps = null, rdma_ports = null, recommended_alternatives = null, resize_compatible_shapes = null, supported_resource_management = null },
      ]
    }
  }

  mock_data "oci_core_images" {
    defaults = {
      images = [
        { id = "ocid1.image.oc1..mock", agent_features = null, base_image_id = null, billable_size_in_gbs = null, compartment_id = null, create_image_allowed = null, defined_tags = null, display_name = null, freeform_tags = null, image_source_details = null, instance_id = null, launch_mode = null, launch_options = null, listing_type = null, operating_system = null, operating_system_version = null, size_in_mbs = null, state = null, time_created = null },
      ]
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

run "budget_alert_is_created_with_an_email" {
  command = plan

  variables {
    budget_alert_emails = ["me@example.com"]
  }

  assert {
    condition     = output.budget_alert == true
    error_message = "An alert email creates the budget."
  }
}
