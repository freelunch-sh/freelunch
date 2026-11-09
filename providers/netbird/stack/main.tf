locals {
  inventory_state = coalesce(var.inventory_state_path, "${path.module}/../../../hybrid/terraform.tfstate")
}

# The hybrid inventory, read from state like the other glue stacks. Without one (the first
# apply, which only makes the setup key), there are no hosts to look up.
data "terraform_remote_state" "inventory" {
  count = fileexists(local.inventory_state) ? 1 : 0

  backend = "local"
  config  = { path = local.inventory_state }
}

locals {
  hosts = { for h in try(data.terraform_remote_state.inventory[0].outputs.hosts, []) : "${h.provider}-${h.name}" => "${var.name_prefix}-${h.provider}-${h.name}" }
}

# A reusable key hosts join with on first boot (netbird_setup_key in the host stacks).
resource "netbird_setup_key" "join" {
  name           = "${var.name_prefix}-hosts"
  type           = "reusable"
  ephemeral      = false
  auto_groups    = var.auto_groups
  expiry_seconds = var.key_expiry_days * 86400
  usage_limit    = 0
}

# A host that hasn't joined yet isn't found and fails the apply: run it again once the hosts are up.
data "netbird_peer" "host" {
  for_each = local.hosts

  name = each.value
}
