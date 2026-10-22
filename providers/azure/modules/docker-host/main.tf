resource "azurerm_resource_group" "this" {
  name     = "${var.name_prefix}-rg"
  location = var.location
  tags     = { "managed-by" = "freelunch" }
}

module "network" {
  source = "../network"

  name                = var.name_prefix
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  ssh_source_cidrs    = var.ssh_source_cidrs
  ingress_tcp_ports   = var.ingress_tcp_ports
  ingress_udp_ports   = var.ingress_udp_ports
}

module "bootstrap" {
  source   = "../../../../shared/modules/docker-bootstrap"
  for_each = var.instances

  admin_user             = var.admin_username
  apps                   = each.value.apps
  swap_size_gb           = each.value.swap_size_gb
  tailscale_auth_key     = var.tailscale_auth_key
  tailscale_hostname     = "${var.name_prefix}-azure-${each.key}"
  max_encoded_size_bytes = 65536 # Azure custom data limit (64 KB)
}

module "compute" {
  source = "../compute"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  subnet_id           = module.network.subnet_id
  name_prefix         = var.name_prefix
  admin_username      = var.admin_username
  ssh_public_keys     = var.ssh_public_keys

  acknowledge_public_ipv4_charge = var.acknowledge_public_ipv4_charge
  acknowledge_billable_resources = var.acknowledge_billable_resources

  instances = {
    for k, v in var.instances : k => {
      size             = v.size
      os_disk_gb       = v.os_disk_gb
      os_disk_type     = v.os_disk_type
      assign_public_ip = v.assign_public_ip
      zone             = v.zone
      user_data        = module.bootstrap[k].user_data
    }
  }
}
