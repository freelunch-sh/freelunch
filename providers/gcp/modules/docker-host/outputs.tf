output "hosts" {
  description = "Docker hosts in the freelunch host contract shape."
  value       = module.compute.hosts
}

output "network_id" {
  description = "ID of the VPC network."
  value       = module.network.network_id
}

output "subnet_id" {
  description = "ID of the subnet."
  value       = module.network.subnet_id
}

output "free_tier_usage" {
  description = "Free tier consumption planned by this module."
  value       = module.compute.free_tier_usage
}
