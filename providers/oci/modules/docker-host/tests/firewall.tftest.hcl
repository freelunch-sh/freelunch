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
