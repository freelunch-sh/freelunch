variable "region" {
  description = "Region the instances run in. The free e2-micro exists only in us-west1, us-central1 and us-east1."
  type        = string
}

variable "subnet_id" {
  description = "Subnetwork ID (or self link) the instances attach to. Must be in `region`."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for instance names."
  type        = string
  default     = "freelunch"
}

variable "ssh_user" {
  description = "Login user the SSH keys are installed for. Ubuntu images use `ubuntu`."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_keys" {
  description = "SSH public keys authorized for `ssh_user`."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "Provide at least one SSH public key."
  }
}

variable "instances" {
  description = <<-EOT
    Instances to create, keyed by short name (the instance is named <name_prefix>-<key>).
    zone: null uses <region>-b.
    image: null uses the latest Ubuntu 24.04 LTS for the machine type's architecture.
    network_tier: STANDARD includes 200 GB/month of free internet egress per region.
    user_data: plain-text cloud-init, applied on first boot only.
  EOT
  type = map(object({
    machine_type     = optional(string, "e2-micro")
    zone             = optional(string)
    disk_gb          = optional(number, 30)
    disk_type        = optional(string, "pd-standard")
    image            = optional(string)
    assign_public_ip = optional(bool, true)
    network_tier     = optional(string, "STANDARD")
    user_data        = optional(string)
  }))

  validation {
    condition     = alltrue([for name in keys(var.instances) : can(regex("^[a-z][a-z0-9-]{0,30}$", name))])
    error_message = "Instance names must start with a letter and contain at most 31 lowercase letters, digits or hyphens."
  }

  validation {
    condition     = alltrue([for i in var.instances : contains(["STANDARD", "PREMIUM"], i.network_tier)])
    error_message = "network_tier must be STANDARD or PREMIUM."
  }
}

variable "acknowledge_public_ipv4_charge" {
  description = "Accept the external IPv4 charge ($0.005/h, about $3.65/month per address), which the free tier does not cover."
  type        = bool
  default     = false
}

variable "acknowledge_billable_resources" {
  description = "Allow configurations outside the free tier (other machine types, regions or disk types, more instances or disk). These are billed."
  type        = bool
  default     = false
}
