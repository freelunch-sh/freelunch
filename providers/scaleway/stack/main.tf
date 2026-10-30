# Scaleway containers have no Terraform resources freelunch needs: `freelunch apply scaleway`
# makes the namespace through the Serverless Containers API, `freelunch deploy` a container
# per app, and `freelunch destroy scaleway` deletes both. This stack declares the target:
# which project, region and size, and refuses an always-on size the free grant doesn't cover.

locals {
  # The CPU share (mVCPU) Scaleway pairs with each memory size, in MB.
  mvcpu = { "128" = 70, "256" = 140, "512" = 280, "1024" = 560, "2048" = 1120, "3072" = 1680, "4096" = 2240 }

  # The free grant per month, and a month of always-on seconds.
  free_gb_seconds   = 400000
  free_vcpu_seconds = 200000
  month_seconds     = 730 * 3600

  # What min_scale containers cost in the grant when they never stop.
  always_on_gb_seconds   = var.memory_mb / 1024 * var.min_scale * local.month_seconds
  always_on_vcpu_seconds = local.mvcpu[tostring(var.memory_mb)] / 1000 * var.min_scale * local.month_seconds
}

resource "terraform_data" "target" {
  input = {
    project   = var.project_id
    region    = var.region
    memory_mb = var.memory_mb
    min_scale = var.min_scale
  }

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || (local.always_on_gb_seconds <= local.free_gb_seconds && local.always_on_vcpu_seconds <= local.free_vcpu_seconds)
      error_message = "${var.min_scale} always-on container(s) of ${var.memory_mb} MB use ${floor(local.always_on_gb_seconds)} GB-s and ${floor(local.always_on_vcpu_seconds)} vCPU-s a month, and the free grant is ${local.free_gb_seconds} and ${local.free_vcpu_seconds}. Use 128 MB with min_scale = 1, scale to zero (min_scale = 0), or set acknowledge_billable_resources = true."
    }
  }
}
