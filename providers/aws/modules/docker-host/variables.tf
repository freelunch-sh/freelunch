variable "region" {
  description = "Region the AWS provider is configured for."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "freelunch"
}

variable "availability_zone" {
  description = "Pin the hosts to this AZ. null picks the first AZ that offers every instance type."
  type        = string
  default     = null
}

variable "ssh_public_keys" {
  description = "SSH public keys authorized on every instance (installed by cloud-init)."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "Provide at least one SSH public key."
  }
}

variable "ssh_source_cidrs" {
  description = "CIDRs allowed to reach SSH. Empty closes SSH (e.g. Tailscale-only access)."
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
  description = "Docker hosts to create. See providers/aws/README.md for Free plan layouts."
  type = map(object({
    instance_type    = optional(string, "t3.micro")
    root_volume_gb   = optional(number, 20)
    root_volume_type = optional(string, "gp3")
    assign_public_ip = optional(bool, true)
    cpu_credits      = optional(string, "standard")
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

variable "acknowledge_billable_resources" {
  description = "Allow instance types, volume types or CPU credit modes outside the Free plan."
  type        = bool
  default     = false
}
