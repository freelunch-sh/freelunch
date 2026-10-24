output "targets" {
  description = "Deploy plan per target: whether it is a host (reached over SSH, at this address and user) or a container platform, its CPU architecture, apps with absolute file paths, whether a tunnel runs there, and its public URLs."
  value       = local.targets

  precondition {
    condition     = length(local.unknown_hosts) == 0
    error_message = "Apps point at hosts that are not in the inventory: ${join(", ", local.unknown_hosts)}. Known hosts: ${length(local.known) > 0 ? join(", ", sort(local.known)) : "none"}. Apply the host stack first (freelunch apply oci), or give the host an address under `hosts` in apps.tfvars."
  }

  precondition {
    condition     = length(local.missing_files) == 0
    error_message = "Files listed in apps.tfvars do not exist: ${join(", ", local.missing_files)}."
  }
}

output "platforms" {
  description = "Deploy plan per container platform target: the provider's ID for it (the Northflank project), region and plan, and a service per app from its Compose file."
  value = {
    for h, t in local.targets : h => {
      provider = local.platforms[h].provider
      id       = local.platforms[h].id
      region   = local.platforms[h].region
      size     = local.platforms[h].size
      services = { for name, a in t.apps : name => try(local.specs[name], null) }
    } if t.kind == "platform"
  }

  precondition {
    condition     = length(local.platform_problems) == 0
    error_message = "These apps can't run on a container platform as they are:\n- ${join("\n- ", local.platform_problems)}"
  }

  precondition {
    condition     = length(local.too_many) == 0
    error_message = "${join(". ", local.too_many)}. Move an app to another target, or allow paid services with acknowledge_billable_resources = true in that stack."
  }

  precondition {
    condition     = length(local.route_problems) == 0
    error_message = "Routes in the cloudflare stack don't match apps.tfvars:\n- ${join("\n- ", local.route_problems)}"
  }
}

output "tunnel_tokens" {
  description = "cloudflared token for each target that has a tunnel."
  value       = { for h in local.target_hosts : h => local.tokens[h] if contains(keys(local.tunnels), h) }
  sensitive   = true
}

output "registries" {
  description = "Registries to log in to on every target host, or to save as credentials on a platform."
  value       = var.registries
}
