variable "region" {
  description = "Region the AWS provider is configured for (reported in the host contract)."
  type        = string
}

variable "subnet_id" {
  description = "Subnet the instances attach to."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups attached to every instance."
  type        = list(string)
}

variable "name_prefix" {
  description = "Prefix for instance Name tags."
  type        = string
  default     = "freelunch"
}

variable "ssh_user" {
  description = "Login user of the image (reported in the host contract). Ubuntu AMIs use `ubuntu`."
  type        = string
  default     = "ubuntu"
}

variable "key_name" {
  description = "Existing EC2 key pair to install. docker-host leaves this null and installs keys through cloud-init instead, since a key pair holds one key."
  type        = string
  default     = null
}

variable "instances" {
  description = <<-EOT
    Instances to create, keyed by short name (the Name tag is <name_prefix>-<key>).
    instance_type: one of the Free plan types (t3.micro, t3.small, t4g.micro, t4g.small,
    c7i-flex.large, m7i-flex.large). t4g is Arm (arm64).
    cpu_credits: "standard" for burstable types, so bursts throttle instead of billing.
    user_data: plain-text cloud-init (max 16 KB), applied on first boot only.
  EOT
  type = map(object({
    instance_type    = optional(string, "t3.micro")
    root_volume_gb   = optional(number, 20)
    root_volume_type = optional(string, "gp3")
    assign_public_ip = optional(bool, true)
    cpu_credits      = optional(string, "standard")
    user_data        = optional(string)
  }))

  validation {
    condition     = alltrue([for name in keys(var.instances) : can(regex("^[a-z][a-z0-9-]{0,30}$", name))])
    error_message = "Instance names must start with a letter and contain at most 31 lowercase letters, digits or hyphens."
  }

  validation {
    condition     = alltrue([for i in var.instances : contains(["standard", "unlimited"], i.cpu_credits)])
    error_message = "cpu_credits must be standard or unlimited."
  }
}

variable "ubuntu_codename" {
  description = "Ubuntu release codename in Canonical's AMI names."
  type        = string
  default     = "noble"
}

variable "ubuntu_version" {
  description = "Ubuntu release number in Canonical's AMI names. The shared Docker bootstrap targets Ubuntu."
  type        = string
  default     = "24.04"
}

variable "acknowledge_billable_resources" {
  description = "Allow instance types, volume types or CPU credit modes outside the Free plan. These are billed once credits run out."
  type        = bool
  default     = false
}
