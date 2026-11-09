# A YugabyteDB Aeon Sandbox cluster per entry in databases (cluster_tier = "FREE"). A Sandbox is
# one node with up to 2 vCPUs and 10 GB, 15 connections, 500 tables or 12.5 million rows, no
# backups; Yugabyte allows one per account and pauses it after 10 days without activity.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
  # Only databases with an allow list get one; a Sandbox cannot be reached without it.
  allowed = { for k, d in var.databases : k => d if length(d.allow_cidrs) > 0 }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_clusters
      error_message = "A Yugabyte account has ${local.limits.max_clusters} Sandbox cluster; this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }
  }
}

resource "random_password" "this" {
  for_each = var.databases

  length  = 24
  special = false
}

resource "ybm_allow_list" "this" {
  for_each = local.allowed

  allow_list_name        = "${local.names[each.key]}-allow"
  allow_list_description = "freelunch: ${local.names[each.key]}"
  cidr_list              = each.value.allow_cidrs
}

resource "ybm_cluster" "this" {
  for_each = var.databases

  cluster_name = local.names[each.key]
  cluster_type = "SYNCHRONOUS"
  cluster_tier = "FREE"
  cloud_type   = each.value.cloud

  cluster_region_info = [{
    region    = each.value.region
    num_nodes = 1
    num_cores = 2
  }]

  cluster_allow_list_ids = contains(keys(local.allowed), each.key) ? [ybm_allow_list.this[each.key].allow_list_id] : []

  credentials = {
    username = each.value.username
    password = random_password.this[each.key].result
  }

  depends_on = [terraform_data.checks]
}
