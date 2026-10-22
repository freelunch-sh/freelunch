output "hosts" {
  description = "Created VMs in the freelunch host contract shape (docs/architecture.md)."
  value = [
    for k, vm in azurerm_linux_virtual_machine.this : {
      provider   = "azure"
      name       = k
      id         = vm.id
      public_ip  = try(azurerm_public_ip.this[k].ip_address, null)
      private_ip = vm.private_ip_address
      ssh_user   = var.admin_username
      arch       = local.instance_arch[k]
      region     = var.location
      size       = vm.size
    }
  ]
}

output "free_tier_usage" {
  description = "12-month free services consumption planned by this module (used/cap), plus billed IPv4 addresses."
  value = {
    vms_by_size         = { for size, n in local.vms_per_size : size => "${n}/${local.free_tier.compute.max_instances_per_size}" }
    p6_disks            = "${local.p6_disks}/${local.disk.max_os_disks}"
    billed_public_ipv4s = length(local.public_ipv4)
  }
}
