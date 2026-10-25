# Private B2 buckets, each with an application key that can only reach that bucket. Apps
# use them over B2's S3-compatible API: freelunch deploy puts the endpoint, region, bucket
# and key into the environment of the app that names the bucket in apps.tfvars.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, b in var.buckets : k => coalesce(b.name, "${var.name_prefix}-${k}") }
  # https://s3.us-west-004.backblazeb2.com: the region is the part after s3.
  region = regex("^https://s3\\.([a-z0-9-]+)\\.", data.b2_account_info.this.s3_api_url)[0]
}

data "b2_account_info" "this" {}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = alltrue([for n in values(local.names) : can(regex("^[a-z0-9][a-z0-9-]{5,62}$", n)) && !startswith(n, "b2-")])
      error_message = "B2 bucket names have 6 to 63 lowercase letters, digits and hyphens, and don't start with b2-: ${join(", ", sort(values(local.names)))}."
    }
  }
}

resource "b2_bucket" "this" {
  for_each = local.names

  bucket_name = each.value
  bucket_type = "allPrivate"
  bucket_info = { managed_by = "freelunch" }

  # B2 keeps every version of a file by default, and old versions use the free storage too.
  lifecycle_rules {
    file_name_prefix                                       = ""
    days_from_hiding_to_deleting                           = var.keep_old_versions_days
    days_from_starting_to_canceling_unfinished_large_files = 1
  }

  depends_on = [terraform_data.checks]
}

resource "b2_application_key" "this" {
  for_each = local.names

  key_name     = each.value
  bucket_ids   = [b2_bucket.this[each.key].bucket_id]
  capabilities = local.limits.key_capabilities
}
