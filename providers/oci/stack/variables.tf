variable "region" {
  description = "Your tenancy's home region, e.g. eu-frankfurt-1. Always Free resources exist only there."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (the `tenancy=` line in ~/.oci/config)."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment to deploy into. null uses the root compartment."
  type        = string
  default     = null
}

variable "oci_auth" {
  description = "OCI provider auth method: ApiKey (default) or SecurityToken (after `oci session authenticate`)."
  type        = string
  default     = "ApiKey"
}

variable "oci_config_profile" {
  description = "Profile in ~/.oci/config to use."
  type        = string
  default     = "DEFAULT"
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "freelunch"
}

variable "ssh_public_keys" {
  description = "SSH public keys authorized on every instance."
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
  description = "Docker hosts to create. See providers/oci/README.md for free-tier layouts."
  type = map(object({
    shape                     = optional(string, "VM.Standard.A1.Flex")
    ocpus                     = optional(number, 2)
    memory_in_gbs             = optional(number, 12)
    boot_volume_gb            = optional(number, 50)
    availability_domain_index = optional(number)
    swap_size_gb              = optional(number, 0)
    apps = optional(map(object({
      compose = string
      env     = optional(map(string), {})
    })), {})
  }))
  default = {
    main = {
      shape          = "VM.Standard.A1.Flex"
      ocpus          = 2
      memory_in_gbs  = 12
      boot_volume_gb = 100
    }
  }
}

variable "availability_domain_offset" {
  description = "Set by freelunch apply --wait-for-capacity, which tries the next availability domain that offers the shape on each retry. Leave it at 0; pin a domain with availability_domain_index instead."
  type        = number
  default     = 0
}

variable "tailscale_auth_key" {
  description = "Optional Tailscale auth key; hosts join your tailnet on first boot."
  type        = string
  default     = null
  sensitive   = true
}

variable "reserved_block_storage_gb" {
  description = "Block storage already used elsewhere in the tenancy, counted against the 200 GB cap."
  type        = number
  default     = 0
}

variable "acknowledge_billable_resources" {
  description = "Allow configurations above the Always Free caps or outside the home region."
  type        = bool
  default     = false
}
