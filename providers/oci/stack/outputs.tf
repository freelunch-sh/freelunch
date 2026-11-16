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

output "quota_guard" {
  description = "Whether a quota keeps compute to the Always Free shapes."
  value       = module.quota_guard.enabled
}

output "budget_alert" {
  description = "Whether a budget alert watches the tenancy."
  value       = module.budget.enabled
}
