# Runs offline: `terraform test` / `tofu test` from providers/gcp/modules/compute.

mock_provider "google" {}

variables {
  region                         = "us-central1"
  subnet_id                      = "projects/mock/regions/us-central1/subnetworks/freelunch-public"
  ssh_public_keys                = ["ssh-ed25519 AAAAmock test"]
  acknowledge_public_ipv4_charge = true
}

run "free_layout_passes" {
  command = plan

  variables {
    instances = { main = {} }
  }

  assert {
    condition     = output.free_tier_usage.e2_micro_instances == "1/1" && output.free_tier_usage.standard_disk_gb == "30/30"
    error_message = "The default instance should use the whole free allowance: 1 e2-micro, 30 GB pd-standard."
  }

  assert {
    condition     = google_compute_instance.this["main"].zone == "us-central1-b" && google_compute_instance.this["main"].boot_disk[0].initialize_params[0].type == "pd-standard"
    error_message = "Defaults should be zone b and a pd-standard disk."
  }

  assert {
    condition     = google_compute_instance.this["main"].boot_disk[0].initialize_params[0].image == "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
    error_message = "e2-micro should boot the amd64 Ubuntu 24.04 image family."
  }

  assert {
    condition     = google_compute_instance.this["main"].metadata["ssh-keys"] == "ubuntu:ssh-ed25519 AAAAmock test" && google_compute_instance.this["main"].metadata["enable-oslogin"] == "FALSE"
    error_message = "SSH keys must be in USER:KEY form and OS Login disabled, or the keys are ignored."
  }

  assert {
    condition     = google_compute_instance.this["main"].network_interface[0].access_config[0].network_tier == "STANDARD"
    error_message = "Standard tier carries 200 GB/month of free egress."
  }

  assert {
    condition     = google_compute_instance.this["main"].scheduling[0].provisioning_model == "STANDARD" && !google_compute_instance.this["main"].scheduling[0].preemptible
    error_message = "Spot and preemptible VMs are not free."
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

run "private_only_host_needs_no_acknowledgement" {
  command = plan

  variables {
    instances                      = { main = { assign_public_ip = false } }
    acknowledge_public_ipv4_charge = false
  }

  assert {
    condition     = length(google_compute_instance.this["main"].network_interface[0].access_config) == 0 && output.free_tier_usage.billed_public_ipv4s == 0
    error_message = "assign_public_ip = false should create no access config."
  }
}

run "second_instance_is_blocked" {
  command = plan

  variables {
    instances = {
      a = { disk_gb = 15 }
      b = { disk_gb = 15 }
    }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "non_free_region_is_blocked" {
  command = plan

  variables {
    region    = "europe-west1"
    instances = { main = {} }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "non_free_machine_type_is_blocked" {
  command = plan

  variables {
    instances = { main = { machine_type = "e2-small" } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "balanced_disk_is_blocked" {
  command = plan

  variables {
    instances = { main = { disk_type = "pd-balanced" } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "disk_over_30gb_is_blocked" {
  command = plan

  variables {
    instances = { main = { disk_gb = 50 } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "zone_outside_region_is_blocked_even_when_acknowledged" {
  command = plan

  variables {
    instances                      = { main = { zone = "us-east1-b" } }
    acknowledge_billable_resources = true
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "acknowledged_billing_allows_arm" {
  command = plan

  variables {
    instances                      = { main = { machine_type = "t2a-standard-1", disk_type = "pd-balanced" } }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = google_compute_instance.this["main"].boot_disk[0].initialize_params[0].image == "ubuntu-os-cloud/ubuntu-2404-lts-arm64"
    error_message = "Arm machine types should boot the arm64 image family."
  }

  assert {
    condition     = output.hosts[0].arch == "arm64" && output.free_tier_usage.e2_micro_instances == "0/1"
    error_message = "Usage output should report what is actually free."
  }
}
