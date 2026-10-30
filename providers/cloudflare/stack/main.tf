data "cloudflare_zone" "this" {
  filter = { name = var.zone }
}

locals {
  inventory_state = coalesce(var.inventory_state_path, "${path.module}/../../../hybrid/terraform.tfstate")
  account_id      = coalesce(var.account_id, data.cloudflare_zone.this.account.id)
}

# The hybrid inventory, read from state like hybrid/ reads the host stacks. A missing
# file is reported by the checks below instead of failing inside the data source.
data "terraform_remote_state" "inventory" {
  count = fileexists(local.inventory_state) ? 1 : 0

  backend = "local"
  config  = { path = local.inventory_state }
}

locals {
  inventory_hosts = [for h in try(data.terraform_remote_state.inventory[0].outputs.hosts, []) : "${h.provider}-${h.name}"]
  # On a container platform (Northflank), cloudflared is a service of its own and reaches
  # each app by its service name, which is the app's name in apps.tfvars.
  platforms     = { for p in try(data.terraform_remote_state.inventory[0].outputs.platforms, []) : "${p.provider}-${p.name}" => p }
  unknown_hosts = sort(tolist(setsubtract(values(local.route_host), concat(local.inventory_hosts, keys(local.platforms)))))
  outside_zone  = [for h in keys(var.routes) : h if h != var.zone && !endswith(h, ".${var.zone}")]
  no_app        = sort([for h, r in var.routes : h if contains(keys(local.platforms), local.route_host[h]) && r.app == null])
  no_tunnel     = sort([for h, r in var.routes : "${h} (${local.route_host[h]})" if !try(local.platforms[local.route_host[h]].tunnel, true)])

  route_host = { for h, r in var.routes : h => try(coalesce(r.host, var.default_host), "no host") }

  routes = {
    for h, r in var.routes : h => {
      host   = local.route_host[h]
      port   = r.port
      scheme = r.scheme
      origin = contains(keys(local.platforms), local.route_host[h]) ? coalesce(r.app, "localhost") : "localhost"
      access = r.access
    }
  }
}

resource "terraform_data" "checks" {
  input = sort(keys(var.routes))

  lifecycle {
    precondition {
      condition     = length(local.unknown_hosts) == 0
      error_message = "Routes point at hosts that are not in the inventory: ${join(", ", local.unknown_hosts)}. Known hosts: ${length(local.inventory_hosts) > 0 ? join(", ", local.inventory_hosts) : "none (apply a host stack first, e.g. freelunch apply oci)"}."
    }

    precondition {
      condition     = length(local.outside_zone) == 0
      error_message = "These hostnames are not in the ${var.zone} zone: ${join(", ", local.outside_zone)}."
    }

    precondition {
      condition     = length(local.no_app) == 0
      error_message = "These routes go to a container platform, where every app is a service of its own, so they need app = \"<name>\", the app in apps.tfvars that serves them: ${join(", ", local.no_app)}."
    }

    precondition {
      condition     = length(local.no_tunnel) == 0
      error_message = "These routes go to a platform that can't run cloudflared: ${join(", ", local.no_tunnel)}."
    }
  }
}

module "tunnel" {
  source = "../modules/tunnel"

  account_id             = local.account_id
  zone_id                = data.cloudflare_zone.this.id
  name_prefix            = var.name_prefix
  routes                 = local.routes
  service_token_duration = var.service_token_duration

  depends_on = [terraform_data.checks]
}

# --- R2 buckets ------------------------------------------------------------------------
#
# A private bucket per entry in buckets, and an account token that can only read, write and
# list its objects. R2's S3 API takes the token's ID as the access key and the SHA-256 of its
# value as the secret, so deploy can hand the app both.

locals {
  r2_names = { for k, b in var.buckets : k => "${var.name_prefix}-${k}" }
  # Cloudflare's name for reading, writing and listing the objects of a bucket; its ID is
  # looked up by name.
  r2_permissions = ["Workers R2 Storage Bucket Item Write"]
  r2_groups = var.r2_permission_group_id != null ? [var.r2_permission_group_id] : [
    for g in try(data.cloudflare_account_api_token_permission_groups_list.all[0].result, []) : g.id if contains(local.r2_permissions, g.name)
  ]
}

data "cloudflare_account_api_token_permission_groups_list" "all" {
  count = length(var.buckets) > 0 && var.r2_permission_group_id == null ? 1 : 0

  account_id = local.account_id
}

resource "terraform_data" "r2_checks" {
  count = length(var.buckets) > 0 ? 1 : 0

  input = sort(values(local.r2_names))

  lifecycle {
    precondition {
      condition     = alltrue([for n in values(local.r2_names) : can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", n))])
      error_message = "R2 bucket names have 3 to 63 lowercase letters, digits and hyphens, and don't end in a hyphen: ${join(", ", sort(values(local.r2_names)))}."
    }

    precondition {
      condition     = length(local.r2_groups) == length(local.r2_permissions)
      error_message = "Cloudflare didn't list the permission ${join(" and ", local.r2_permissions)}, which an R2 key needs. The API token needs Account > API Tokens > Edit (providers/cloudflare/README.md#r2-buckets)."
    }
  }
}

resource "cloudflare_r2_bucket" "this" {
  for_each = local.r2_names

  account_id = local.account_id
  name       = each.value
  location   = var.buckets[each.key].location

  depends_on = [terraform_data.r2_checks]
}

resource "cloudflare_account_token" "r2" {
  for_each = local.r2_names

  account_id = local.account_id
  name       = "freelunch R2 ${each.value}"
  policies = [{
    effect            = "allow"
    permission_groups = [for id in local.r2_groups : { id = id }]
    resources         = jsonencode({ "com.cloudflare.edge.r2.bucket.${local.account_id}_default_${cloudflare_r2_bucket.this[each.key].name}" = "*" })
  }]
}
