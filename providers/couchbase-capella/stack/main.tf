# A free-tier Capella cluster per entry in databases, in its own project, with a bucket, an
# allow-list and a database user. The free tier is one operational cluster per organisation,
# deleted by Couchbase after 30 days without activity.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}-${k}" }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.databases) <= local.limits.max_clusters
      error_message = "The free tier has ${local.limits.max_clusters} operational cluster per organisation; this asks for ${length(var.databases)}. Set acknowledge_billable_resources = true to go on."
    }

    precondition {
      condition     = alltrue([for d in var.databases : contains(["aws", "azure", "gcp"], d.cloud)])
      error_message = "cloud is aws, azure or gcp."
    }
  }
}

resource "random_password" "db" {
  for_each = var.databases

  length           = 32
  special          = true
  override_special = "!#$%^*-_"
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "couchbase-capella_project" "this" {
  for_each = var.databases

  organization_id = var.organization_id
  name            = local.names[each.key]

  depends_on = [terraform_data.checks]
}

resource "couchbase-capella_free_tier_cluster" "this" {
  for_each = var.databases

  organization_id = var.organization_id
  project_id      = couchbase-capella_project.this[each.key].id
  name            = local.names[each.key]

  cloud_provider = {
    type   = each.value.cloud
    region = each.value.region
    cidr   = each.value.cidr
  }
}

resource "couchbase-capella_free_tier_bucket" "this" {
  for_each = var.databases

  organization_id = var.organization_id
  project_id      = couchbase-capella_project.this[each.key].id
  cluster_id      = couchbase-capella_free_tier_cluster.this[each.key].id
  name            = each.value.bucket
}

resource "couchbase-capella_allowlist" "this" {
  for_each = { for pair in setproduct(keys(var.databases), var.allowed_cidrs) : "${pair[0]}|${pair[1]}" => { db = pair[0], cidr = pair[1] } }

  organization_id = var.organization_id
  project_id      = couchbase-capella_project.this[each.value.db].id
  cluster_id      = couchbase-capella_free_tier_cluster.this[each.value.db].id
  cidr            = each.value.cidr
}

resource "couchbase-capella_database_credential" "this" {
  for_each = var.databases

  organization_id = var.organization_id
  project_id      = couchbase-capella_project.this[each.key].id
  cluster_id      = couchbase-capella_free_tier_cluster.this[each.key].id
  name            = "app"
  password        = random_password.db[each.key].result

  access = [{
    privileges = ["data_reader", "data_writer"]
    resources = {
      buckets = [{ name = couchbase-capella_free_tier_bucket.this[each.key].name }]
    }
  }]
}
