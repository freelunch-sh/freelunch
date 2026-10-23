variable "tenancy_id" {
  description = "Tenancy OCID."
  type        = string
}

variable "compartment_id" {
  description = "Compartment OCID. null uses the tenancy (root compartment)."
  type        = string
  default     = null
}

variable "region" {
  description = "Region the OCI provider is configured for (must be the home region)."
  type        = string
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
  description = "CIDRs allowed to reach SSH. Empty closes SSH (e.g. Tailscale-only access)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ingress_tcp_ports" {
  description = "TCP ports opened in the VCN and in the host firewall."
  type        = list(number)
  default     = [80, 443]
}

variable "ingress_udp_ports" {
  description = "UDP ports opened in the VCN and in the host firewall."
  type        = list(number)
  default     = []
}

variable "instances" {
  description = "Docker hosts to create. See providers/oci/README.md for layouts that fit the free tier."
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
  description = "Moves instances without availability_domain_index to the next availability domain that offers their shape. Set by freelunch apply --wait-for-capacity on each retry."
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
