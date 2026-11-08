# A Supabase project per entry in databases. The free plan has 2 active projects with 500 MB
# of database each, and pauses a project after 7 days without activity (restore it from the
# dashboard). The database password is made here and kept in the state.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_projects
      error_message = "The free plan has ${local.limits.max_projects} active projects; this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }
  }
}

resource "random_password" "db" {
  for_each = var.databases

  length  = 32
  special = false
}

resource "supabase_project" "this" {
  for_each = var.databases

  organization_id   = var.organization_id
  name              = local.names[each.key]
  database_password = random_password.db[each.key].result
  region            = each.value.region

  lifecycle {
    ignore_changes = [database_password]
  }

  depends_on = [terraform_data.checks]
}
