variable "subscription_id" {
  description = "Subscription to deploy into (az account show --query id). null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region, e.g. eastus or westeurope. Check that it offers the sizes you pick."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for all resource names, including the resource group (<name_prefix>-rg)."
  type        = string
  default     = "freelunch"
}

variable "admin_username" {
  description = "Login user created on every VM."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_keys" {
  description = "SSH public keys (RSA >= 2048 bits or Ed25519) authorized on every VM."
  type        = list(string)
}

variable "ssh_source_cidrs" {
  description = "CIDRs allowed to reach SSH. Use your own IP (x.x.x.x/32), or [] with Tailscale."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ingress_tcp_ports" {
  description = "TCP ports open to the internet."
  type        = list(number)
  default     = [80, 443]
}

variable "ingress_udp_ports" {
  description = "UDP ports open to the internet."
  type        = list(number)
  default     = []
}

variable "instances" {
  description = "Docker hosts to create. See providers/azure/README.md for free-tier layouts."
  type = map(object({
    size             = optional(string, "Standard_B2ats_v2")
    os_disk_gb       = optional(number, 64)
    os_disk_type     = optional(string, "Premium_LRS")
    assign_public_ip = optional(bool, true)
    zone             = optional(string)
    swap_size_gb     = optional(number, 2)
    apps = optional(map(object({
      compose = string
      env     = optional(map(string), {})
    })), {})
  }))
  default = {
    main = {}
  }
}

variable "tailscale_auth_key" {
  description = "Optional Tailscale auth key; hosts join your tailnet on first boot."
  type        = string
  default     = null
  sensitive   = true
}

variable "acknowledge_public_ipv4_charge" {
  description = "Accept the Standard public IPv4 charge (about $3.65/month per address), which the free tier does not cover."
  type        = bool
  default     = false
}

variable "acknowledge_billable_resources" {
  description = "Allow sizes, disks or VM counts outside the 12-month free services."
  type        = bool
  default     = false
}
