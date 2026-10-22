module "docker_host" {
  source = "../modules/docker-host"

  location       = var.location
  name_prefix    = var.name_prefix
  admin_username = var.admin_username

  ssh_public_keys   = var.ssh_public_keys
  ssh_source_cidrs  = var.ssh_source_cidrs
  ingress_tcp_ports = var.ingress_tcp_ports
  ingress_udp_ports = var.ingress_udp_ports

  instances          = var.instances
  tailscale_auth_key = var.tailscale_auth_key

  acknowledge_public_ipv4_charge = var.acknowledge_public_ipv4_charge
  acknowledge_billable_resources = var.acknowledge_billable_resources
}
