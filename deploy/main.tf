# Turns apps.tfvars, the hybrid inventory and the Cloudflare tunnels into one deploy plan
# per host. It reads state only and creates nothing; bin/freelunch reads the outputs and
# does the SSH part.

data "terraform_remote_state" "inventory" {
  count = fileexists(var.inventory_state_path) ? 1 : 0

  backend = "local"
  config  = { path = var.inventory_state_path }
}

data "terraform_remote_state" "tunnels" {
  count = try(fileexists(var.tunnel_state_path), false) ? 1 : 0

  backend = "local"
  config  = { path = var.tunnel_state_path }
}

locals {
  inventory = { for h in try(data.terraform_remote_state.inventory[0].outputs.hosts, []) : "${h.provider}-${h.name}" => h }
  tunnels   = try(data.terraform_remote_state.tunnels[0].outputs.tunnels, {})
  tokens    = try(data.terraform_remote_state.tunnels[0].outputs.tunnel_tokens, {})
  routes    = try(data.terraform_remote_state.tunnels[0].outputs.routes, {})

  # Reachable hosts: everything in the inventory, plus overrides that give an address.
  known = setunion(keys(local.inventory), [for h, o in var.hosts : h if o.address != null])

  apps = {
    for name, a in var.apps : name => {
      host     = a.host
      compose  = abspath(startswith(pathexpand(a.compose), "/") ? pathexpand(a.compose) : "${var.config_dir}/${a.compose}")
      env_file = a.env_file == null ? null : abspath(startswith(pathexpand(a.env_file), "/") ? pathexpand(a.env_file) : "${var.config_dir}/${a.env_file}")
    }
  }

  app_hosts = distinct([for a in var.apps : a.host])
  # A tunnel whose host is gone (destroyed, renamed) is skipped rather than blocking deploys elsewhere.
  tunnel_hosts = [for h in keys(local.tunnels) : h if contains(local.known, h)]
  target_hosts = sort(distinct(concat(local.app_hosts, local.tunnel_hosts)))

  unknown_hosts = sort([for name, a in var.apps : "${name} (host ${a.host})" if !contains(local.known, a.host)])
  missing_files = sort(compact(flatten([
    for a in local.apps : [
      fileexists(a.compose) ? "" : a.compose,
      a.env_file == null ? "" : (fileexists(a.env_file) ? "" : a.env_file),
    ]
  ])))

  targets = {
    for h in local.target_hosts : h => {
      provider = try(local.inventory[h].provider, null)
      address  = try(coalesce(try(var.hosts[h].address, null), try(local.inventory[h].public_ip, null), try(local.inventory[h].private_ip, null)), null)
      user     = try(coalesce(try(var.hosts[h].user, null), try(local.inventory[h].ssh_user, null)), "ubuntu")
      arch     = try(local.inventory[h].arch, null)
      apps     = { for name, a in local.apps : name => { compose = a.compose, env_file = a.env_file } if a.host == h }
      tunnel   = contains(keys(local.tunnels), h)
      urls     = sort([for hostname, r in local.routes : "https://${hostname}" if r.host == h])
    }
  }
}
