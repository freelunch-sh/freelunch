# A compartment quota at the tenancy's root that forbids every compute shape but the Always Free ones: every
# compute-core and compute-memory quota is zeroed, and then the Arm A1 cores and memory and the AMD micro shape get
# the Always Free amounts, which the catalogue (provider.yaml) holds. A launch outside them is refused by OCI itself,
# on a pay-as-you-go tenancy too, where a budget alert would only report the charge.
#
# Quota statements are evaluated in order, and a later one supersedes an earlier one for the same quota. Service limits
# still apply on top of a quota. Names and syntax: docs.oracle.com/en-us/iaas/Content/Quotas (Compute Quotas, Quota
# Policy Syntax). Not run against a real tenancy.
locals {
  free_tier = yamldecode(file("${path.module}/../../provider.yaml")).limits
  a1        = local.free_tier.compute.a1_flex
  micro     = local.free_tier.compute.e2_micro

  statements = [
    "zero compute-core quotas in tenancy",
    "zero compute-memory quotas in tenancy",
    "set compute-core quota standard-a1-core-count to ${local.a1.max_ocpus} in tenancy",
    "set compute-memory quota standard-a1-memory-count to ${local.a1.max_memory_gb} in tenancy",
    "set compute-core quota standard-e2-micro-core-count to ${local.micro.max_instances} in tenancy",
  ]
}

resource "oci_limits_quota" "this" {
  count = var.enabled ? 1 : 0

  compartment_id = var.tenancy_id
  name           = "${var.name}-always-free-only"
  description    = "freelunch: only the Always Free compute shapes may be launched in this tenancy"
  statements     = local.statements

  lifecycle {
    precondition {
      condition     = !var.allow_billable
      error_message = "quota_guard forbids what is not Always Free, and acknowledge_billable_resources allows it: choose one."
    }
  }
}
