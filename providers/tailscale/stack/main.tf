locals {
  inventory_state = coalesce(var.inventory_state_path, "${path.module}/../../../hybrid/terraform.tfstate")
}

# The hybrid inventory, read from state like the other glue stacks. Without one (the first
# apply, which only makes the join key), there are no hosts to look up.
data "terraform_remote_state" "inventory" {
  count = fileexists(local.inventory_state) ? 1 : 0

  backend = "local"
  config  = { path = local.inventory_state }
}

locals {
  hosts = { for h in try(data.terraform_remote_state.inventory[0].outputs.hosts, []) : "${h.provider}-${h.name}" => "${var.name_prefix}-${h.provider}-${h.name}" }
}

# A reusable key hosts join with on first boot (tailscale_auth_key in the host stacks).
resource "tailscale_tailnet_key" "join" {
  reusable      = true
  ephemeral     = false
  preauthorized = true
  expiry        = var.key_expiry_days * 86400
  description   = "freelunch hosts"
  tags          = var.tags
}

# A host that hasn't joined yet is waited for for a minute, then fails the apply: run it again
# once the hosts are up.
data "tailscale_device" "host" {
  for_each = local.hosts

  hostname = each.value
  wait_for = "60s"
}
