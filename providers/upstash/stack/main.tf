# An Upstash Redis database per entry in databases. The free plan has 250 MB of data, 500K
# commands a month and 10 GB of bandwidth per database; at the limit commands are rejected
# rather than billed. Only the database count is checked here.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_databases
      error_message = "The free plan has ${local.limits.max_databases} database(s); this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }
  }
}

resource "upstash_redis_database" "this" {
  for_each = var.databases

  database_name  = local.names[each.key]
  region         = "global"
  primary_region = each.value.primary_region
  eviction       = each.value.eviction
  tls            = true
  # Never turn on the paid add-ons.
  auto_scale = false
  prod_pack  = false

  depends_on = [terraform_data.checks]
}
