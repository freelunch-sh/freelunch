output "hosts" {
  description = "Docker hosts in the freelunch host contract shape."
  value       = module.compute.hosts
}

output "resource_group_name" {
  description = "Resource group holding everything this module creates."
  value       = azurerm_resource_group.this.name
}

output "vnet_id" {
  description = "ID of the virtual network."
  value       = module.network.vnet_id
}

output "subnet_id" {
  description = "ID of the subnet."
  value       = module.network.subnet_id
}

output "free_tier_usage" {
  description = "12-month free services consumption planned by this module."
  value       = module.compute.free_tier_usage
}
