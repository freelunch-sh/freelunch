output "vnet_id" {
  description = "ID of the virtual network."
  value       = azurerm_virtual_network.this.id
}

output "subnet_id" {
  description = "ID of the subnet, available once the NSG is attached so hosts never boot without its rules."
  value       = azurerm_subnet_network_security_group_association.public.subnet_id
}

output "network_security_group_id" {
  description = "ID of the network security group."
  value       = azurerm_network_security_group.this.id
}

output "ingress" {
  description = "What the NSG admits from outside: SSH source CIDRs and TCP/UDP ports (null when there is no rule)."
  value = {
    ssh_source_cidrs = one([for r in azurerm_network_security_group.this.security_rule : sort(r.source_address_prefixes) if r.name == "ssh"])
    tcp_ports        = one([for r in azurerm_network_security_group.this.security_rule : sort(r.destination_port_ranges) if r.name == "tcp"])
    udp_ports        = one([for r in azurerm_network_security_group.this.security_rule : sort(r.destination_port_ranges) if r.name == "udp"])
  }
}
