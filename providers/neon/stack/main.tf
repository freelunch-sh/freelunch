# A Neon project per entry in databases. Neon's free plan allows 100 projects, each with
# 100 compute-hours a month and 1 GB of storage (20 GB in total), and scales a project to zero
# after 5 minutes without a connection. Only the limits are checked here: the plan itself
# is chosen in the Neon console.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_projects
      error_message = "The free plan has ${local.limits.max_projects} projects; this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for d in var.databases : d.max_cu <= local.limits.max_cu])
      error_message = "The free plan autoscales to ${local.limits.max_cu} compute units at most. Lower max_cu, or set acknowledge_billable_resources = true."
    }

    precondition {
      condition     = alltrue([for d in var.databases : contains(local.limits.pg_versions, d.pg_version)])
      error_message = "pg_version is one of ${join(", ", local.limits.pg_versions)}."
    }
  }
}

resource "neon_project" "this" {
  for_each = var.databases

  name                     = local.names[each.key]
  org_id                   = var.org_id
  region_id                = each.value.region_id
  pg_version               = each.value.pg_version
  autoscaling_limit_min_cu = 0.25
  autoscaling_limit_max_cu = each.value.max_cu
  store_password           = "yes"

  branch {
    name          = "main"
    database_name = each.value.database_name
    role_name     = each.value.role_name
  }

  depends_on = [terraform_data.checks]
}
