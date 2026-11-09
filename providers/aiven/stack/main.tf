# A free Aiven service per entry in databases: PostgreSQL or Valkey. The free plan allows one
# service of each type per organisation (single node, 1 CPU, 1 GB RAM, 1 GB disk) and powers
# a service off after a period of inactivity (power it back on from the console).

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
  plans  = { for k, d in var.databases : k => coalesce(d.plan, local.limits.free_plan) }
  pg     = { for k, d in var.databases : k => d if d.engine == "pg" }
  valkey = { for k, d in var.databases : k => d if d.engine == "valkey" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = alltrue([for d in var.databases : contains(local.limits.engines, d.engine)])
      error_message = "engine is one of ${join(", ", local.limits.engines)}."
    }

    precondition {
      condition = var.acknowledge_billable_resources || alltrue([
        for e in local.limits.engines : length([for d in var.databases : d if d.engine == e]) <= local.limits.max_per_engine
      ])
      error_message = "The free plan has ${local.limits.max_per_engine} service of each type (${join(", ", local.limits.engines)}) per organisation. Set acknowledge_billable_resources = true to go on."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for p in values(local.plans) : p == local.limits.free_plan])
      error_message = "Only the free plan (${local.limits.free_plan}) is free. Drop plan, or set acknowledge_billable_resources = true."
    }
  }
}

resource "aiven_pg" "this" {
  for_each = local.pg

  project      = var.project
  service_name = local.names[each.key]
  cloud_name   = each.value.cloud_name
  plan         = local.plans[each.key]

  depends_on = [terraform_data.checks]
}

resource "aiven_valkey" "this" {
  for_each = local.valkey

  project      = var.project
  service_name = local.names[each.key]
  cloud_name   = each.value.cloud_name
  plan         = local.plans[each.key]

  depends_on = [terraform_data.checks]
}
