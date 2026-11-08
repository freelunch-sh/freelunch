# An Astra DB serverless database per entry in databases. The free plan allows 5 databases,
# hibernates one that is idle for 48 hours and deletes it after 30 days of hibernation.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_databases
      error_message = "The free plan has ${local.limits.max_databases} serverless databases; this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }

    precondition {
      condition     = alltrue([for d in var.databases : contains(local.limits.clouds, d.cloud_provider)])
      error_message = "cloud_provider is one of ${join(", ", local.limits.clouds)}."
    }
  }
}

resource "astra_database" "this" {
  for_each = var.databases

  name           = local.names[each.key]
  keyspace       = each.value.keyspace
  cloud_provider = each.value.cloud_provider
  regions        = [each.value.region]

  depends_on = [terraform_data.checks]
}

resource "astra_token" "this" {
  for_each = length(var.token_role_ids) > 0 ? var.databases : {}

  roles = var.token_role_ids
}
