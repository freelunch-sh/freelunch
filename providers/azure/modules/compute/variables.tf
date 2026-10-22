variable "resource_group_name" {
  description = "Resource group for the VMs, NICs and public IPs."
  type        = string
}

variable "location" {
  description = "Azure region. Free sizes are free in any region that offers them."
  type        = string
}

variable "subnet_id" {
  description = "Subnet the NICs attach to."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "freelunch"
}

variable "admin_username" {
  description = "Login user created on every VM."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_keys" {
  description = "SSH public keys (RSA >= 2048 bits or Ed25519) authorized for admin_username."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "Provide at least one SSH public key."
  }
}

variable "instances" {
  description = <<-EOT
    VMs to create, keyed by short name (also the hostname).
    size: Standard_B2ats_v2 (AMD), Standard_B2pts_v2 (Arm) or Standard_B1s are free.
    os_disk_gb: 33-64 on Premium_LRS bills as the free P6 tier.
    zone: availability zone ("1", "2", "3"), or null for no zone.
    user_data: plain-text cloud-init (max 64 KB encoded), applied on first boot only.
  EOT
  type = map(object({
    size             = optional(string, "Standard_B2ats_v2")
    os_disk_gb       = optional(number, 64)
    os_disk_type     = optional(string, "Premium_LRS")
    assign_public_ip = optional(bool, true)
    zone             = optional(string)
    user_data        = optional(string)
  }))

  validation {
    condition     = alltrue([for name in keys(var.instances) : can(regex("^[a-z][a-z0-9-]{0,30}$", name))])
    error_message = "Instance names must start with a letter and contain at most 31 lowercase letters, digits or hyphens."
  }
}

variable "image_offer" {
  description = "Canonical image offer. The shared Docker bootstrap targets Ubuntu."
  type        = string
  default     = "ubuntu-24_04-lts"
}

variable "acknowledge_public_ipv4_charge" {
  description = "Accept the Standard public IPv4 charge (about $3.65/month per address), which the free tier does not cover."
  type        = bool
  default     = false
}

variable "acknowledge_billable_resources" {
  description = "Allow sizes, disks or VM counts outside the 12-month free services. These are billed on pay-as-you-go."
  type        = bool
  default     = false
}
