# `hosts` is the freelunch contract output; hybrid/ aggregates it across providers.
output "hosts" {
  description = "Docker hosts created by this stack."
  value       = module.docker_host.hosts
}

output "ssh" {
  description = "SSH command per host."
  value       = { for h in module.docker_host.hosts : h.name => "ssh ${h.ssh_user}@${coalesce(h.public_ip, h.private_ip)}" }
}

output "free_tier_usage" {
  description = "12-month free services consumption (used/cap), plus billed IPv4 addresses."
  value       = module.docker_host.free_tier_usage
}
