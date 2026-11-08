# A CockroachDB Cloud Basic cluster per entry in databases. Basic includes $15 of usage a month
# (50M request units and 10 GiB of storage) across the whole organisation, and the account needs
# a payment method on file to get it. The per-cluster limits below are set to that allowance so
# a cluster stops (is throttled) before it bills; the checks sum them across clusters.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || sum([for d in var.databases : d.request_unit_limit]) <= local.limits.free_request_units
      error_message = "The free allowance is ${local.limits.free_request_units} request units a month across all clusters. Lower request_unit_limit, or set acknowledge_billable_resources = true."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || sum([for d in var.databases : d.storage_mib_limit]) <= local.limits.free_storage_mib
      error_message = "The free allowance is ${local.limits.free_storage_mib} MiB of storage across all clusters. Lower storage_mib_limit, or set acknowledge_billable_resources = true."
    }
  }
}

resource "random_password" "db" {
  for_each = var.databases

  length  = 32
  special = false
}

resource "cockroach_cluster" "this" {
  for_each = var.databases

  name           = local.names[each.key]
  cloud_provider = each.value.cloud_provider
  plan           = "BASIC"

  serverless = {
    usage_limits = {
      request_unit_limit = each.value.request_unit_limit
      storage_mib_limit  = each.value.storage_mib_limit
    }
  }

  regions = [{
    name = each.value.region
  }]

  depends_on = [terraform_data.checks]
}

resource "cockroach_sql_user" "this" {
  for_each = var.databases

  cluster_id = cockroach_cluster.this[each.key].id
  name       = each.value.user
  password   = random_password.db[each.key].result
}
