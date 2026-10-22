output "targets" {
  description = "Deploy plan per host: SSH address and user, apps with absolute file paths, whether a tunnel runs there, and its public URLs."
  value       = local.targets

  precondition {
    condition     = length(local.unknown_hosts) == 0
    error_message = "Apps point at hosts that are not in the inventory: ${join(", ", local.unknown_hosts)}. Known hosts: ${length(local.inventory) > 0 ? join(", ", keys(local.inventory)) : "none"}. Apply the host stack first (freelunch apply oci), or give the host an address under `hosts` in apps.tfvars."
  }

  precondition {
    condition     = length(local.missing_files) == 0
    error_message = "Files listed in apps.tfvars do not exist: ${join(", ", local.missing_files)}."
  }
}

output "tunnel_tokens" {
  description = "cloudflared token for each target host that has a tunnel."
  value       = { for h in local.target_hosts : h => local.tokens[h] if contains(keys(local.tunnels), h) }
  sensitive   = true
}

output "registries" {
  description = "Registries to log in to on every target host."
  value       = var.registries
}
