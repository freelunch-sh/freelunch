variable "name" {
  description = "Name prefix for network resources."
  type        = string
  default     = "freelunch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must start with a letter and contain 2-41 lowercase letters, digits or hyphens."
  }
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block of the public subnet. Must sit inside vpc_cidr."
  type        = string
  default     = "10.0.1.0/24"
}

variable "instance_types" {
  description = "Instance types that will run in the subnet; the subnet goes to an AZ that offers all of them."
  type        = list(string)
  default     = []
}

variable "availability_zone" {
  description = "Pin the subnet to this AZ. null picks the first AZ that offers every instance type."
  type        = string
  default     = null
}

variable "ssh_source_cidrs" {
  description = "CIDRs (IPv4 or IPv6) allowed to reach SSH (22/tcp). An empty list closes SSH, e.g. when you only use Tailscale."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ingress_tcp_ports" {
  description = "TCP ports open to the internet (besides SSH)."
  type        = list(number)
  default     = [80, 443]
}

variable "ingress_udp_ports" {
  description = "UDP ports open to the internet."
  type        = list(number)
  default     = []
}
