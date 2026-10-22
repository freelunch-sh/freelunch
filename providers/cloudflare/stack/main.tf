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
  unknown_hosts   = sort(tolist(setsubtract([for r in var.routes : r.host], local.inventory_hosts)))
  outside_zone    = [for h in keys(var.routes) : h if h != var.zone && !endswith(h, ".${var.zone}")]
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
  }
}

module "tunnel" {
  source = "../modules/tunnel"

  account_id  = coalesce(var.account_id, data.cloudflare_zone.this.account.id)
  zone_id     = data.cloudflare_zone.this.id
  name_prefix = var.name_prefix
  routes      = var.routes

  depends_on = [terraform_data.checks]
}
