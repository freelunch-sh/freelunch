# A TiDB Cloud Starter (serverless) cluster per entry in databases. The free quota is 5 clusters
# per organisation, each with 5 GiB of row storage, 5 GiB of columnar storage and 50M request
# units a month. A spending limit of 0 means the cluster never bills: at the quota it refuses
# new connections instead.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_clusters
      error_message = "The free quota covers ${local.limits.max_clusters} Starter clusters per organisation; this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for d in var.databases : d.monthly_spending_limit <= local.limits.max_spending_limit_cents])
      error_message = "A spending limit above ${local.limits.max_spending_limit_cents} can bill your card. Lower monthly_spending_limit, or set acknowledge_billable_resources = true."
    }
  }
}

resource "tidbcloud_serverless_cluster" "this" {
  for_each = var.databases

  display_name = local.names[each.key]
  project_id   = var.project_id

  region = {
    name = each.value.region
  }

  spending_limit = {
    monthly = each.value.monthly_spending_limit
  }

  depends_on = [terraform_data.checks]
}
