locals {
  inventory_state = coalesce(var.inventory_state_path, "${path.module}/../../../hybrid/terraform.tfstate")
}

# The hybrid inventory, read from state like the other glue stacks. A missing file is reported
# by the check below.
data "terraform_remote_state" "inventory" {
  count = fileexists(local.inventory_state) ? 1 : 0

  backend = "local"
  config  = { path = local.inventory_state }
}

locals {
  public_ips = { for h in try(data.terraform_remote_state.inventory[0].outputs.hosts, []) : "${h.provider}-${h.name}" => h.public_ip if try(h.public_ip, null) != null }
  # What each record points at: its host's public IP, or the value given
  targets = { for k, r in var.records : k => r.host != null ? try(local.public_ips[r.host], null) : r.value }
  # A host without a public IP, or outside the inventory, can't be an A record
  unresolved = sort([for k, r in var.records : "${k} (${r.host})" if r.host != null && !contains(keys(local.public_ips), r.host)])
}

resource "terraform_data" "checks" {
  input = sort(keys(var.records))

  lifecycle {
    precondition {
      condition     = length(local.unresolved) == 0
      error_message = "These records point at hosts with no public IP in the inventory: ${join(", ", local.unresolved)}. Known: ${length(local.public_ips) > 0 ? join(", ", sort(keys(local.public_ips))) : "none (apply a host stack first, e.g. freelunch apply oci)"}."
    }
  }
}
