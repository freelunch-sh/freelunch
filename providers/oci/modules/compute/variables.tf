variable "tenancy_id" {
  description = "Tenancy OCID. Used to look up availability domains and the home region."
  type        = string
}

variable "compartment_id" {
  description = "Compartment OCID for the instances."
  type        = string
}

variable "region" {
  description = "Region the OCI provider is configured for. Must be the tenancy's home region to stay Always Free."
  type        = string
}

variable "subnet_id" {
  description = "Subnet OCID the instances attach to."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for instance display names."
  type        = string
  default     = "freelunch"
}

variable "ssh_public_keys" {
  description = "SSH public keys authorized for the default user."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "Provide at least one SSH public key."
  }
}

variable "instances" {
  description = <<-EOT
    Instances to create, keyed by short name (also used as the hostname).
    shape: VM.Standard.A1.Flex (Arm) or VM.Standard.E2.1.Micro (AMD).
    ocpus / memory_in_gbs apply to flexible shapes only.
    availability_domain_index: null picks the first AD that offers the shape (see
    availability_domain_offset).
    user_data: plain-text cloud-init, applied on first boot only.
  EOT
  type = map(object({
    shape                     = optional(string, "VM.Standard.A1.Flex")
    ocpus                     = optional(number, 2)
    memory_in_gbs             = optional(number, 12)
    boot_volume_gb            = optional(number, 50)
    availability_domain_index = optional(number)
    assign_public_ip          = optional(bool, true)
    user_data                 = optional(string)
  }))

  validation {
    condition     = alltrue([for name in keys(var.instances) : can(regex("^[a-z][a-z0-9-]{0,30}$", name))])
    error_message = "Instance names must start with a letter and contain at most 31 lowercase letters, digits or hyphens."
  }
}

variable "availability_domain_offset" {
  description = "Places instances without availability_domain_index in the next availability domain that offers their shape, wrapping around. freelunch apply --wait-for-capacity raises it by one on each retry. A created instance stays where it is."
  type        = number
  default     = 0

  validation {
    condition     = var.availability_domain_offset >= 0 && floor(var.availability_domain_offset) == var.availability_domain_offset
    error_message = "availability_domain_offset must be a whole number, 0 or more."
  }
}

variable "operating_system" {
  description = "Platform image operating system."
  type        = string
  default     = "Canonical Ubuntu"
}

variable "operating_system_version" {
  description = "Platform image version. The shared Docker bootstrap targets Ubuntu."
  type        = string
  default     = "24.04"
}

variable "preserve_boot_volume" {
  description = "Keep boot volumes when instances are destroyed. Preserved volumes still count toward the 200 GB cap."
  type        = bool
  default     = false
}

variable "reserved_block_storage_gb" {
  description = "Block storage already used elsewhere in the tenancy, counted against the 200 GB Always Free cap."
  type        = number
  default     = 0
}

variable "acknowledge_billable_resources" {
  description = "Allow configurations above the Always Free caps or outside the home region. These are billed on Pay-As-You-Go accounts."
  type        = bool
  default     = false
}
