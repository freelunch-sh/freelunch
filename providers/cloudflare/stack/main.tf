data "cloudflare_zone" "this" {
  filter = { name = var.zone }
}

locals {
  inventory_state = coalesce(var.inventory_state_path, "${path.module}/../../../hybrid/terraform.tfstate")
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
  unknown_hosts = sort(tolist(setsubtract([for r in var.routes : r.host], concat(local.inventory_hosts, keys(local.platforms)))))
  outside_zone  = [for h in keys(var.routes) : h if h != var.zone && !endswith(h, ".${var.zone}")]
  no_app        = sort([for h, r in var.routes : h if contains(keys(local.platforms), r.host) && r.app == null])
  no_tunnel     = sort([for h, r in var.routes : "${h} (${r.host})" if !try(local.platforms[r.host].tunnel, true)])

  routes = {
    for h, r in var.routes : h => {
      host   = r.host
      port   = r.port
      scheme = r.scheme
      origin = contains(keys(local.platforms), r.host) ? coalesce(r.app, "localhost") : "localhost"
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

  account_id             = coalesce(var.account_id, data.cloudflare_zone.this.account.id)
  zone_id                = data.cloudflare_zone.this.id
  name_prefix            = var.name_prefix
  routes                 = local.routes
  service_token_duration = var.service_token_duration

  depends_on = [terraform_data.checks]
}
