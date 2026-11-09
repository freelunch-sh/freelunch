# An AuraDB Free instance per entry in databases (type free-db, 1 GB). Free allows one database
# with 200k nodes and 400k relationships; it pauses itself after 72 hours without activity and is
# deleted, with no way to recover the data, after 30 days paused.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_instances
      error_message = "AuraDB Free allows ${local.limits.max_instances} instance; this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }
  }
}

resource "neo4jaura_instance" "this" {
  for_each = var.databases

  name           = local.names[each.key]
  project_id     = var.project_id
  type           = local.limits.instance_type
  memory         = local.limits.memory
  version        = "5"
  cloud_provider = each.value.cloud_provider
  region         = each.value.region

  depends_on = [terraform_data.checks]
}
