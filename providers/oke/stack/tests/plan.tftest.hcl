# Runs offline: `terraform test` / `tofu test` from providers/oke/stack.
# Plans the stack against a mocked OCI API.

mock_provider "oci" {
  mock_data "oci_identity_availability_domains" {
    defaults = {
      availability_domains = [{ name = "Xyz:EU-FRANKFURT-1-AD-1", id = "ad1", compartment_id = "ocid1.tenancy.oc1..mock" }]
    }
  }

  mock_data "oci_containerengine_cluster_option" {
    defaults = {
      kubernetes_versions = ["v1.32.1", "v1.33.1"]
    }
  }

  mock_data "oci_containerengine_node_pool_option" {
    defaults = {
      sources = [
        { source_name = "Oracle-Linux-8.10-aarch64-2026.09.30-0-OKE-1.33.1-1100", image_id = "ocid1.image.oc1..arm133", source_type = "IMAGE" },
        { source_name = "Oracle-Linux-8.10-aarch64-2026.09.30-0-OKE-1.32.1-1090", image_id = "ocid1.image.oc1..arm132", source_type = "IMAGE" },
        { source_name = "Oracle-Linux-8.10-2026.09.30-0-OKE-1.33.1-1100", image_id = "ocid1.image.oc1..x86133", source_type = "IMAGE" },
      ]
    }
  }
}

variables {
  region           = "eu-frankfurt-1"
  tenancy_ocid     = "ocid1.tenancy.oc1..mock"
  ssh_public_key   = "ssh-ed25519 AAAAmock test"
  api_source_cidrs = ["203.0.113.7/32"]
}

run "one_free_arm_node_by_default" {
  command = plan

  assert {
    condition     = oci_containerengine_cluster.this.type == "BASIC_CLUSTER" && oci_containerengine_cluster.this.kubernetes_version == "v1.33.1"
    error_message = "The cluster is a Basic one (no control-plane fee) at the newest Kubernetes version."
  }

  assert {
    condition     = oci_containerengine_node_pool.this.node_shape == "VM.Standard.A1.Flex" && oci_containerengine_node_pool.this.node_config_details[0].size == 1
    error_message = "The node pool is one Always Free Arm node."
  }

  assert {
    condition     = oci_containerengine_node_pool.this.node_source_details[0].image_id == "ocid1.image.oc1..arm133"
    error_message = "The node image is the OKE Arm one for the cluster's Kubernetes version."
  }
}

run "an_older_version_takes_its_own_image" {
  command = plan

  variables {
    kubernetes_version = "v1.32.1"
  }

  assert {
    condition     = oci_containerengine_node_pool.this.node_source_details[0].image_id == "ocid1.image.oc1..arm132"
    error_message = "The image follows kubernetes_version."
  }
}

run "nodes_beyond_the_free_cores_fail" {
  command = plan

  variables {
    node_count = 2
  }

  expect_failures = [oci_containerengine_cluster.this]
}

run "an_older_tenancy_fits_two_nodes" {
  command = plan

  variables {
    node_count         = 2
    free_a1_ocpus      = 4
    free_a1_memory_gbs = 24
  }

  assert {
    condition     = output.cluster.arm_ocpus == 4 && output.cluster.nodes == 2
    error_message = "Two 2-OCPU nodes fit a tenancy with 4 free OCPUs."
  }
}

run "paying_lifts_the_limit" {
  command = plan

  variables {
    node_count                     = 3
    acknowledge_billable_resources = true
  }

  assert {
    condition     = output.cluster.arm_ocpus == 6
    error_message = "With acknowledge_billable_resources, any number of nodes is allowed."
  }
}
