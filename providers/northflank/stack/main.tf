# Northflank has no Terraform provider for projects and services, so this stack declares
# the target: which project, where, and on which plan. `freelunch apply northflank` then
# creates the project through Northflank's API, `freelunch deploy` puts a service per app
# in it, and `freelunch destroy northflank` deletes them again.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
}

resource "terraform_data" "project" {
  input = {
    id     = var.name_prefix
    region = var.region
    plan   = var.plan
  }

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || contains(local.limits.plans, var.plan)
      error_message = "The free Sandbox runs the plans ${join(" and ", local.limits.plans)}, not ${var.plan}. Set acknowledge_billable_resources = true to use it on a paid plan."
    }
  }
}
