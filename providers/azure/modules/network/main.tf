locals {
  tags = { "managed-by" = "freelunch" }
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "public" {
  name                 = "${var.name}-public"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidr]
}

# Azure appends its default rules (allow VNet and load balancer, deny the rest inbound,
# allow internet outbound) after these.
resource "azurerm_network_security_group" "this" {
  name                = "${var.name}-hosts"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  dynamic "security_rule" {
    for_each = length(var.ssh_source_cidrs) > 0 ? [1] : []
    content {
      name                       = "ssh"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefixes    = var.ssh_source_cidrs
      destination_address_prefix = "*"
    }
  }

  dynamic "security_rule" {
    for_each = length(var.ingress_tcp_ports) > 0 ? [1] : []
    content {
      name                       = "tcp"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_ranges    = [for p in var.ingress_tcp_ports : tostring(p)]
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }

  dynamic "security_rule" {
    for_each = length(var.ingress_udp_ports) > 0 ? [1] : []
    content {
      name                       = "udp"
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_ranges    = [for p in var.ingress_udp_ports : tostring(p)]
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }

  # Ping and path MTU discovery. NSG rules can't filter by ICMP type.
  security_rule {
    name                       = "icmp"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.this.id
}
