output "hosts" {
  description = "Docker hosts in the freelunch host contract shape."
  value       = module.compute.hosts
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "subnet_id" {
  description = "ID of the public subnet."
  value       = module.network.subnet_id
}

output "security_group_id" {
  description = "ID of the hosts' security group."
  value       = module.network.security_group_id
}

output "free_tier_usage" {
  description = "What this module plans. On the Free plan all of it draws down the credit."
  value       = module.compute.free_tier_usage
}
