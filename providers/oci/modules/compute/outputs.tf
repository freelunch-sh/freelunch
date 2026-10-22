output "hosts" {
  description = "Created instances in the freelunch host contract shape (docs/architecture.md)."
  value = [
    for k, i in oci_core_instance.this : {
      provider   = "oci"
      name       = k
      id         = i.id
      public_ip  = i.public_ip
      private_ip = i.private_ip
      ssh_user   = "ubuntu"
      arch       = i.shape == local.a1_shape ? "arm64" : "amd64"
      region     = var.region
      size       = i.shape
    }
  ]
}

output "home_region" {
  description = "The tenancy's home region."
  value       = local.home_region
}

output "free_tier_usage" {
  description = "Always Free consumption planned by this module."
  value = {
    a1_ocpus         = "${local.a1_ocpus}/${local.free_tier.compute.a1_flex.max_ocpus}"
    a1_memory_gb     = "${local.a1_memory_gb}/${local.free_tier.compute.a1_flex.max_memory_gb}"
    micro_instances  = "${length(local.micro_instances)}/${local.free_tier.compute.e2_micro.max_instances}"
    block_storage_gb = "${local.block_storage_gb}/${local.free_tier.storage.max_block_storage_gb}"
  }
}
