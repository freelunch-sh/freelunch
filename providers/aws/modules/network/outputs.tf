output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "subnet_id" {
  description = "ID of the public subnet."
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "ID of the hosts' security group."
  value       = aws_security_group.this.id
}

output "availability_zone" {
  description = "AZ chosen for the subnet (null lets AWS choose)."
  value       = local.availability_zone
}

output "ingress" {
  description = "What the security group admits from outside: SSH source CIDRs and TCP/UDP ports."
  value = {
    ssh_source_cidrs = toset(keys(aws_vpc_security_group_ingress_rule.ssh))
    tcp_ports        = toset([for r in aws_vpc_security_group_ingress_rule.tcp : r.from_port])
    udp_ports        = toset([for r in aws_vpc_security_group_ingress_rule.udp : r.from_port])
  }
}
