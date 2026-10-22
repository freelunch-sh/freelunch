output "hosts" {
  description = "Created instances in the freelunch host contract shape (docs/architecture.md)."
  value = [
    for k, i in google_compute_instance.this : {
      provider   = "gcp"
      name       = k
      id         = i.id
      public_ip  = try(i.network_interface[0].access_config[0].nat_ip, null)
      private_ip = i.network_interface[0].network_ip
      ssh_user   = var.ssh_user
      arch       = local.instance_arch[k]
      region     = var.region
      size       = i.machine_type
    }
  ]
}

output "free_tier_usage" {
  description = "Free tier consumption planned by this module (used/cap), plus billed IPv4 addresses."
  value = {
    e2_micro_instances  = "${length(local.micro_instances)}/${local.free_tier.compute.max_instances}"
    standard_disk_gb    = "${local.standard_disk_gb}/${local.free_tier.storage.max_disk_gb}"
    billed_public_ipv4s = local.public_ipv4
  }
}
