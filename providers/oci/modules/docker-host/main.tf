locals {
  compartment_id = coalesce(var.compartment_id, var.tenancy_id)

  # OCI's Ubuntu images ship iptables rules that reject inbound traffic even when the
  # VCN allows it. Open each port live, and persist it by editing rules.v4 directly:
  # `netfilter-persistent save` would also capture Docker's chains and break Docker
  # networking on the next boot.
  host_firewall_rules = concat(
    [for p in var.ingress_tcp_ports : "-p tcp -m state --state NEW -m tcp --dport ${p}"],
    [for p in var.ingress_udp_ports : "-p udp -m udp --dport ${p}"],
  )

  host_firewall_runcmd = flatten([
    for rule in local.host_firewall_rules : [
      "iptables -C INPUT ${rule} -j ACCEPT 2>/dev/null || iptables -I INPUT ${rule} -j ACCEPT",
      "[ -f /etc/iptables/rules.v4 ] && (grep -qF -- '-A INPUT ${rule} -j ACCEPT' /etc/iptables/rules.v4 || sed -i '/--dport 22 -j ACCEPT/a -A INPUT ${rule} -j ACCEPT' /etc/iptables/rules.v4)",
    ]
  ])
}

module "network" {
  source = "../network"

  compartment_id    = local.compartment_id
  name              = var.name_prefix
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
  extra_packages         = ["iptables-persistent"]
  extra_runcmd           = local.host_firewall_runcmd
  tailscale_auth_key     = var.tailscale_auth_key
  tailscale_hostname     = "${var.name_prefix}-oci-${each.key}"
  max_encoded_size_bytes = 30000 # OCI caps instance metadata at 32,000 bytes; leave room for SSH keys
}

module "compute" {
  source = "../compute"

  tenancy_id     = var.tenancy_id
  compartment_id = local.compartment_id
  region         = var.region
  subnet_id      = module.network.subnet_id
  name_prefix    = var.name_prefix

  ssh_public_keys                = var.ssh_public_keys
  availability_domain_offset     = var.availability_domain_offset
  reserved_block_storage_gb      = var.reserved_block_storage_gb
  acknowledge_billable_resources = var.acknowledge_billable_resources

  instances = {
    for k, v in var.instances : k => {
      shape                     = v.shape
      ocpus                     = v.ocpus
      memory_in_gbs             = v.memory_in_gbs
      boot_volume_gb            = v.boot_volume_gb
      availability_domain_index = v.availability_domain_index
      assign_public_ip          = true
      user_data                 = module.bootstrap[k].user_data
    }
  }
}
