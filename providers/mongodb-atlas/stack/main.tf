# A MongoDB Atlas project with one Free (M0) cluster per entry in databases. M0 has 512 MB of
# storage, 500 connections, 100 operations a second and 10 GB in and out a week, and is paused
# after 30 days without a connection. The cluster is always the M0 tier on a TENANT backing
# provider, so it cannot bill; the checks only cover the cloud provider.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for d in var.databases : contains(local.limits.providers, d.provider_name)])
      error_message = "Free clusters run on ${join(", ", local.limits.providers)}. Set provider_name to one of them, or set acknowledge_billable_resources = true."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_clusters
      error_message = "This allows ${local.limits.max_clusters} free clusters; this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }
  }
}

resource "random_password" "db" {
  for_each = var.databases

  length  = 32
  special = false
}

resource "mongodbatlas_project" "this" {
  for_each = var.databases

  name   = local.names[each.key]
  org_id = var.org_id

  depends_on = [terraform_data.checks]
}

resource "mongodbatlas_advanced_cluster" "this" {
  for_each = var.databases

  project_id   = mongodbatlas_project.this[each.key].id
  name         = local.names[each.key]
  cluster_type = "REPLICASET"

  replication_specs = [{
    region_configs = [{
      provider_name         = "TENANT"
      backing_provider_name = each.value.provider_name
      region_name           = each.value.region_name
      priority              = 7
      electable_specs = {
        instance_size = "M0"
      }
    }]
  }]
}

resource "mongodbatlas_database_user" "this" {
  for_each = var.databases

  project_id         = mongodbatlas_project.this[each.key].id
  username           = each.value.user
  password           = random_password.db[each.key].result
  auth_database_name = "admin"

  roles {
    role_name     = "readWrite"
    database_name = each.value.database_name
  }

  lifecycle {
    ignore_changes = [password]
  }
}

resource "mongodbatlas_project_ip_access_list" "this" {
  for_each = var.databases

  project_id = mongodbatlas_project.this[each.key].id
  cidr_block = each.value.allowed_cidr
  comment    = "freelunch"
}
