# Independent of the host, so it is made in the first apply even while the host waits for
# capacity. (A depends_on would defer the host module's data sources to apply time.)
module "budget" {
  source = "../modules/budget"

  tenancy_id   = var.tenancy_ocid
  name         = var.name_prefix
  amount       = var.budget_amount
  alert_emails = var.budget_alert_emails
}

# A quota that lets only the Always Free compute shapes be launched, so OCI itself refuses the rest (a budget alert only
# reports a charge). Off unless quota_guard = true.
module "quota_guard" {
  source = "../modules/quota-guard"

  tenancy_id     = var.tenancy_ocid
  name           = var.name_prefix
  enabled        = var.quota_guard
  allow_billable = var.acknowledge_billable_resources
}

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

  instances                  = var.instances
  availability_domain_offset = var.availability_domain_offset
  capacity_fallbacks         = var.capacity_fallbacks
  tailscale_auth_key         = var.tailscale_auth_key
  netbird_setup_key          = var.netbird_setup_key

  reserved_block_storage_gb      = var.reserved_block_storage_gb
  acknowledge_billable_resources = var.acknowledge_billable_resources
}
