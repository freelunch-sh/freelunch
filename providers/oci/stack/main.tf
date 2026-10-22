module "docker_host" {
  source = "../modules/docker-host"

  tenancy_id     = var.tenancy_ocid
  compartment_id = var.compartment_ocid
  region         = var.region
  name_prefix    = var.name_prefix

  ssh_public_keys   = var.ssh_public_keys
  ssh_source_cidrs  = var.ssh_source_cidrs
  ingress_tcp_ports = var.ingress_tcp_ports
  ingress_udp_ports = var.ingress_udp_ports

  instances          = var.instances
  tailscale_auth_key = var.tailscale_auth_key

  reserved_block_storage_gb      = var.reserved_block_storage_gb
  acknowledge_billable_resources = var.acknowledge_billable_resources
}
