# Combines every deployed provider stack into one inventory. It reads state only and
# creates nothing, so one provider's failure (e.g. OCI out of capacity) never blocks
# the others, and no provider credentials are needed here.

data "terraform_remote_state" "provider" {
  for_each = toset(concat(var.host_providers, var.platform_providers))

  backend = try(var.state_overrides[each.key].backend, "local")
  config = try(var.state_overrides[each.key].config, {
    path = var.state_dir != null ? "${var.state_dir}/${each.key}/terraform.tfstate" : "${path.module}/../providers/${each.key}/stack/terraform.tfstate"
  })
}

locals {
  hosts_by_provider = {
    for p in var.host_providers : p => try(data.terraform_remote_state.provider[p].outputs.hosts, [])
  }

  hosts = flatten([for p in var.host_providers : local.hosts_by_provider[p]])

  platforms = flatten([for p in var.platform_providers : try(data.terraform_remote_state.provider[p].outputs.platforms, [])])
}
