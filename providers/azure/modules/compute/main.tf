locals {
  free_tier = yamldecode(file("${path.module}/../../provider.yaml")).limits

  free_sizes = local.free_tier.compute.free_sizes
  disk       = local.free_tier.storage

  # Arm sizes carry a "p" in their feature letters: B2pts_v2, D2ps_v5, E4pds_v6.
  instance_arch = {
    for k, v in var.instances : k => lookup(local.free_sizes, v.size, can(regex("^Standard_[A-Z]+[0-9]+[a-z]*p[a-z]*_", v.size)) ? "arm64" : "amd64")
  }

  vms_per_size = { for size, _ in local.free_sizes : size => length([for v in var.instances : v if v.size == size]) }
  p6_disks = length([
    for v in var.instances : v if v.os_disk_type == local.disk.disk_type && v.os_disk_gb >= local.disk.p6_min_gb && v.os_disk_gb <= local.disk.p6_max_gb
  ])
  public_ipv4 = { for k, v in var.instances : k => v if v.assign_public_ip }

  tags = { "managed-by" = "freelunch" }
}

resource "terraform_data" "free_tier_guardrails" {
  input = {
    vms_per_size = local.vms_per_size
    p6_disks     = local.p6_disks
    public_ipv4  = length(local.public_ipv4)
  }

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for i in var.instances : contains(keys(local.free_sizes), i.size)])
      error_message = "Only ${join(", ", keys(local.free_sizes))} are free (750 hours/month each). Set acknowledge_billable_resources = true to use other sizes."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for size, n in local.vms_per_size : n <= local.free_tier.compute.max_instances_per_size])
      error_message = "Each free size covers one VM running all month (750 hours). Use different sizes for a second VM, or set acknowledge_billable_resources = true."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || length(var.instances) <= local.disk.max_os_disks
      error_message = "The free tier covers ${local.disk.max_os_disks} P6 managed disks, so at most ${local.disk.max_os_disks} VMs (each needs an OS disk)."
    }

    precondition {
      condition = var.acknowledge_billable_resources || alltrue([
        for i in var.instances : i.os_disk_type == local.disk.disk_type && i.os_disk_gb >= local.disk.p6_min_gb && i.os_disk_gb <= local.disk.p6_max_gb
      ])
      error_message = "OS disks must be ${local.disk.disk_type} between ${local.disk.p6_min_gb} and ${local.disk.p6_max_gb} GB to bill as the free P6 tier (smaller disks bill as P4)."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || var.acknowledge_public_ipv4_charge || length(local.public_ipv4) == 0
      error_message = "Standard public IPv4 addresses are billed (about $3.65/month each) and are not part of the free tier; the $200 credit covers them for the first 30 days. Set acknowledge_public_ipv4_charge = true to accept the charge, or assign_public_ip = false (new subnets have no default outbound access, so the VM then needs a NAT gateway, which is billed too)."
    }
  }
}

resource "azurerm_public_ip" "this" {
  for_each = local.public_ipv4

  name                = "${var.name_prefix}-${each.key}-ip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = each.value.zone != null ? [each.value.zone] : null
  tags                = local.tags
}

resource "azurerm_network_interface" "this" {
  for_each = var.instances

  name                = "${var.name_prefix}-${each.key}-nic"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = try(azurerm_public_ip.this[each.key].id, null)
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  for_each = var.instances

  name                            = "${var.name_prefix}-${each.key}"
  computer_name                   = each.key
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = each.value.size
  zone                            = each.value.zone
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this[each.key].id]
  custom_data                     = each.value.user_data != null ? base64encode(each.value.user_data) : null
  tags                            = local.tags

  dynamic "admin_ssh_key" {
    for_each = toset(var.ssh_public_keys)
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    name                 = "${var.name_prefix}-${each.key}-os"
    caching              = "ReadWrite"
    storage_account_type = each.value.os_disk_type
    disk_size_gb         = each.value.os_disk_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = var.image_offer
    sku       = local.instance_arch[each.key] == "arm64" ? "server-arm64" : "server"
    version   = "latest"
  }

  lifecycle {
    # Changing cloud-init or SSH keys would replace the VM, and cloud-init only runs on
    # first boot anyway. Rebuild deliberately with `-replace`.
    ignore_changes = [custom_data, admin_ssh_key]
  }

  depends_on = [terraform_data.free_tier_guardrails]
}
