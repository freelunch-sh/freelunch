# Runs offline: `terraform test` / `tofu test` from providers/oci/modules/quota-guard.

mock_provider "oci" {}

variables {
  tenancy_id = "ocid1.tenancy.oc1..mock"
}

run "off_by_default_makes_nothing" {
  command = plan

  assert {
    condition     = output.enabled == false && length(oci_limits_quota.this) == 0 && output.quota_id == null
    error_message = "The guard is off unless asked for."
  }
}

run "on_zeroes_every_compute_family_then_allows_the_free_shapes" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition     = oci_limits_quota.this[0].compartment_id == "ocid1.tenancy.oc1..mock" && oci_limits_quota.this[0].name == "freelunch-always-free-only"
    error_message = "One quota in the tenancy's root compartment."
  }

  assert {
    condition = (
      output.statements[0] == "zero compute-core quotas in tenancy" &&
      output.statements[1] == "zero compute-memory quotas in tenancy" &&
      output.statements[2] == "set compute-core quota standard-a1-core-count to 2 in tenancy" &&
      output.statements[3] == "set compute-memory quota standard-a1-memory-count to 12 in tenancy" &&
      output.statements[4] == "set compute-core quota standard-e2-micro-core-count to 2 in tenancy"
    )
    error_message = "Zero first, then the Always Free amounts from the catalogue (2 OCPUs and 12 GB of Arm, 2 micro VMs): a later statement supersedes an earlier one."
  }

  assert {
    condition     = length(oci_limits_quota.this[0].statements) == 5
    error_message = "The quota carries all five statements."
  }
}

run "it_cant_be_on_while_billable_resources_are_allowed" {
  command = plan

  variables {
    enabled        = true
    allow_billable = true
  }

  expect_failures = [oci_limits_quota.this]
}
