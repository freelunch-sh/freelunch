module "network" {
  source = "../network"

  name              = var.name_prefix
  region            = var.region
  ssh_source_cidrs  = var.ssh_source_cidrs
  ingress_tcp_ports = var.ingress_tcp_ports
  ingress_udp_ports = var.ingress_udp_ports
}

module "bootstrap" {
  source   = "../../../../shared/modules/docker-bootstrap"
  for_each = var.instances

  admin_user             = "ubuntu"
  apps                   = each.value.apps
  swap_size_gb           = each.value.swap_size_gb
  tailscale_auth_key     = var.tailscale_auth_key
  tailscale_hostname     = "${var.name_prefix}-gcp-${each.key}"
  max_encoded_size_bytes = 349528 # base64 size of GCP's 256 KB limit per metadata value
}

module "compute" {
  source = "../compute"

  region          = var.region
  subnet_id       = module.network.subnet_id
  name_prefix     = var.name_prefix
  ssh_public_keys = var.ssh_public_keys

  acknowledge_public_ipv4_charge = var.acknowledge_public_ipv4_charge
  acknowledge_billable_resources = var.acknowledge_billable_resources

  instances = {
    for k, v in var.instances : k => {
      machine_type     = v.machine_type
      zone             = v.zone
      disk_gb          = v.disk_gb
      disk_type        = v.disk_type
      assign_public_ip = v.assign_public_ip
      network_tier     = v.network_tier
      user_data        = module.bootstrap[k].user_data
    }
  }
}
