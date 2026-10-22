module "network" {
  source = "../network"

  name              = var.name_prefix
  instance_types    = distinct([for i in var.instances : i.instance_type])
  availability_zone = var.availability_zone
  ssh_source_cidrs  = var.ssh_source_cidrs
  ingress_tcp_ports = var.ingress_tcp_ports
  ingress_udp_ports = var.ingress_udp_ports
}

module "bootstrap" {
  source   = "../../../../shared/modules/docker-bootstrap"
  for_each = var.instances

  admin_user             = "ubuntu"
  ssh_authorized_keys    = var.ssh_public_keys
  apps                   = each.value.apps
  swap_size_gb           = each.value.swap_size_gb
  tailscale_auth_key     = var.tailscale_auth_key
  tailscale_hostname     = "${var.name_prefix}-aws-${each.key}"
  max_encoded_size_bytes = 21848 # base64 size of EC2's 16 KB user data limit
}

module "compute" {
  source = "../compute"

  region             = var.region
  subnet_id          = module.network.subnet_id
  security_group_ids = [module.network.security_group_id]
  name_prefix        = var.name_prefix

  acknowledge_billable_resources = var.acknowledge_billable_resources

  instances = {
    for k, v in var.instances : k => {
      instance_type    = v.instance_type
      root_volume_gb   = v.root_volume_gb
      root_volume_type = v.root_volume_type
      assign_public_ip = v.assign_public_ip
      cpu_credits      = v.cpu_credits
      user_data        = module.bootstrap[k].user_data
    }
  }
}
