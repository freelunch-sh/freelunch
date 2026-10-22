output "hosts" {
  description = "Docker hosts in the freelunch host contract shape."
  value       = module.compute.hosts
}

output "vcn_id" {
  description = "OCID of the VCN."
  value       = module.network.vcn_id
}

output "subnet_id" {
  description = "OCID of the public subnet."
  value       = module.network.subnet_id
}

output "free_tier_usage" {
  description = "Always Free consumption planned by this module."
  value       = module.compute.free_tier_usage
}
