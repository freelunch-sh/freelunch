output "network_id" {
  description = "ID of the VPC network."
  value       = google_compute_network.this.id
}

output "subnet_id" {
  description = "ID of the subnet."
  value       = google_compute_subnetwork.public.id
}

output "ingress" {
  description = "What the firewall admits from outside: SSH source CIDRs and TCP/UDP ports (null when there is no rule)."
  value = {
    ssh_source_cidrs = try(sort(google_compute_firewall.ssh[0].source_ranges), null)
    tcp_ports        = try(one(google_compute_firewall.tcp[0].allow).ports, null)
    udp_ports        = try(one(google_compute_firewall.udp[0].allow).ports, null)
  }
}
