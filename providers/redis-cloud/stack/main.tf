# A free Redis Cloud Essentials subscription with one database per entry in databases. The
# free plan is one 30 MB database per account, without replication or persistence.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

data "rediscloud_essentials_plan" "free" {
  for_each = var.databases

  size                  = local.limits.size_mb
  size_measurement_unit = "MB"
  cloud_provider        = each.value.cloud_provider
  region                = each.value.region
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_databases
      error_message = "The free plan has ${local.limits.max_databases} database; this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for k, p in data.rediscloud_essentials_plan.free : p.price == 0])
      error_message = "The plan found for the chosen cloud and region is not free. Pick another region, or set acknowledge_billable_resources = true."
    }
  }
}

resource "rediscloud_essentials_subscription" "this" {
  for_each = var.databases

  name    = local.names[each.key]
  plan_id = data.rediscloud_essentials_plan.free[each.key].id

  depends_on = [terraform_data.checks]
}

resource "rediscloud_essentials_database" "this" {
  for_each = var.databases

  subscription_id     = rediscloud_essentials_subscription.this[each.key].id
  name                = local.names[each.key]
  enable_default_user = true
  data_persistence    = "none"
  replication         = false
}
