# `hosts` is the freelunch contract output; hybrid/ aggregates it across providers.
output "hosts" {
  description = "Docker hosts created by this stack."
  value       = module.docker_host.hosts
}

output "ssh" {
  description = "SSH command per host."
  value       = { for h in module.docker_host.hosts : h.name => "ssh ${h.ssh_user}@${h.public_ip}" }
}

output "free_tier_usage" {
  description = "Always Free consumption (used/cap)."
  value       = module.docker_host.free_tier_usage
}
